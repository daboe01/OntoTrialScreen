#!/usr/bin/env perl

# HPO Backend - Upgraded with Native Tool Use, JSON Schema Constraints, Chunking & Dynamic LLM Routing
use Mojolicious::Lite;
use Mojolicious::Plugin::Database;
use SQL::Abstract;
use SQL::Abstract::More;
use Data::Dumper;
use Mojo::UserAgent;
use Apache::Session::File;
use Encode;
use Mojo::JSON qw(decode_json encode_json);
use DBIx::Connector;
use POSIX qw(strftime);

no warnings 'uninitialized';

# =========================================================
# DATABASE CONNECTIONS
# =========================================================
helper connector_db => sub {
    state $db = DBIx::Connector->new('dbi:Pg:dbname=hpo;host=localhost', 'postgres','postgres', { pg_enable_utf8 => 1, AutoCommit => 1 });
};
helper db => sub { shift->connector_db->dbh };

# Turn browser cache off
hook after_dispatch => sub {
    my $tx = shift;
    my $e  = Mojo::Date->new(time - 100);
    $tx->res->headers->header(Expires => $e);
    $tx->res->headers->header('X-ARGOS-Routing' => '3026');
};

# Global CORS Configuration
app->hook(before_dispatch => sub {
          my $c = shift;
          $c->res->headers->header('Access-Control-Allow-Origin'  => '*');
          $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, OPTIONS');
          $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, Authorization');
          if ($c->req->method eq 'OPTIONS') {
          $c->render(text => '', status => 204);
          return;
          }
});

# =========================================================
# GLOBAL CONFIGURATION & LLM SETTINGS
# =========================================================
my $api_key      = $ENV{VLLM_API_KEY}   // 'ap-XX';
my $endpoint     = $ENV{VLLM_ENDPOINT}  // 'https://inference-api.aipier.kn.uniklinik-freiburg.de/v1/chat/completions';
my $model        = $ENV{VLLM_MODEL}     // 'gpt-oss-120b';

# Configuration for Local Testing / LLM Provider Selection
my $llm_provider = $ENV{LLM_PROVIDER}   // 'vllm'; # Options: 'vllm' or 'ollama'
my $ollama_model = $ENV{OLLAMA_MODEL}   // 'gemma4:26b-mlx';

my $patchbay_url = $ENV{PATCHBAY_URL}   // 'http://localhost:3036';

use constant {
    LLM_HPO_RETRIEVAL_PROMPT_ID          => 25,
    LLM_HPO_MODIFIER_RETRIEVAL_PROMPT_ID => 25,
};

# Initialize Mojo::UserAgent with no timeout limits for large generation tasks
my $ua = Mojo::UserAgent->new(request_timeout => 0, inactivity_timeout => 0, connect_timeout => 0);
$ua->max_connections(0);

# =========================================================
# EXTRACTION SCHEMAS (JSON Schema strict constraints)
# =========================================================
my $phenotypic_features_schema = {
    type => 'object',
    properties => {
        phenotypicFeatures => {
            type => 'array',
            items => {
                type => 'object',
                properties => {
                    type => {
                        type => 'object',
                        properties => {
                            label => { type => 'string' }
                        },
                        required => ['label'],
                        additionalProperties => \0
                    },
                    # Add this new property to enable the LLM to classify inclusion vs exclusion
                    exclude => {
                        type => 'boolean',
                        description => 'Set to true if this clinical symptom is listed under Exclusion Criteria (must NOT be present), set to false if it is listed under Inclusion Criteria (must be present).'
                    },
                    severity => {
                        type => 'object',
                        properties => {
                            label => { type => 'string' }
                        },
                        required => ['label'],
                        additionalProperties => \0
                    },
                    onset => {
                        type => 'object',
                        properties => {
                            ontologyClass => {
                                type => 'object',
                                properties => {
                                    label => { type => 'string' }
                                },
                                required => ['label'],
                                additionalProperties => \0
                            }
                        },
                        required => ['ontologyClass'],
                        additionalProperties => \0
                    },
                    modifiers => {
                        type => 'array',
                        items => {
                            type => 'object',
                            properties => {
                                label => { type => 'string' }
                            },
                            required => ['label'],
                            additionalProperties => \0
                        }
                    }
                },
                required => ['type'],
                additionalProperties => \0
            }
        }
    },
    required => ['phenotypicFeatures'],
    additionalProperties => \0
};

my $icd10_schema = {
    type => 'object',
    properties => {
        diagnoses => {
            type => 'array',
            items => {
                type => 'object',
                properties => {
                    code  => { type => 'string', description => 'The explicit ICD-10 code if present, otherwise omit or empty string' },
                    label => { type => 'string', description => 'The clinical condition or standard diagnostic text' }
                },
                required => ['code', 'label'],
                additionalProperties => \0
            }
        }
    },
    required => ['diagnoses'],
    additionalProperties => \0
};

# =========================================================
# CLINICAL PROCESSING UTILITIES & RECOVERY PARSER
# =========================================================

# Robust JSON extraction block parser to recover nested structures from narrative chat responses
sub clean_and_parse_json {
    my ($raw_content) = @_;
    return unless defined $raw_content;

    # 1. Straightforward deserialization check
    my $data = eval { decode_json($raw_content) };
    return $data if $data;

    # 2. Extract from standard Markdown blocks
    if ($raw_content =~ /^\s*```(?:json)?\s*(.*?)\s*```/is) {
        $data = eval { decode_json($1) };
        return $data if $data;
    }

    # 3. Aggressive extraction searching for first '{' and last '}'
    if ($raw_content =~ /(\{.*\})/gs) {
        $data = eval { decode_json($1) };
        return $data if $data;
    }

    return undef;
}

sub create_document_chunks {
    my ($text, $max_chunk_size) = @_;
    $max_chunk_size //= 3000;

    my @paragraphs = split(/(?:\r?\n){2,}/, $text);
    my @chunks;
    my $current = "";

    foreach my $para (@paragraphs) {
        if (length($current) + length($para) > $max_chunk_size) {
            push @chunks, $current if $current;
            $current = $para;
        } else {
            $current .= ($current ? "\n\n" : "") . $para;
        }
    }
    push @chunks, $current if $current;
    return \@chunks;
}

sub merge_extracted_structures {
    my ($accumulated, $new_data, $target_schema) = @_;
    return unless ref $accumulated eq 'HASH' && ref $new_data eq 'HASH' && ref $target_schema eq 'HASH';

    foreach my $key (keys %{$target_schema->{properties}}) {
        my $type = $target_schema->{properties}{$key}{type} // 'string';
        if ($type eq 'array') {
            $accumulated->{$key} //= [];
            if (exists $new_data->{$key} && ref $new_data->{$key} eq 'ARRAY') {
                push @{$accumulated->{$key}}, @{$new_data->{$key}};
            }
        } else {
            if (exists $new_data->{$key} && defined $new_data->{$key} && $new_data->{$key} ne '') {
                $accumulated->{$key} //= $new_data->{$key};
            }
        }
    }
}

helper format_hpo_id => sub {
    my ($self, $raw_id) = @_;
    $raw_id =~ s/\D//g;
    $raw_id = 118 unless $raw_id;
    return sprintf("HP:%07d", $raw_id);
};

helper map_to_hpo_async => sub {
    my ($self, $term, $is_modifier) = @_;
    return Mojo::Promise->resolve(undef) unless $term;

    my $prompt_id = $is_modifier ? LLM_HPO_MODIFIER_RETRIEVAL_PROMPT_ID : LLM_HPO_RETRIEVAL_PROMPT_ID;
    my $url_retrieve = "$patchbay_url/LLM/run_stateless/" . $prompt_id;

    return $ua->post_p($url_retrieve => {Accept => '*/*'} => encode('UTF-8', $term))->then(sub {
        my $tx = shift;
        if ($tx->result && $tx->result->is_success) {
            my $matches = eval { decode_json($tx->result->body) } // [];
            if (ref $matches eq 'ARRAY' && @$matches && defined $matches->[0]->{label}) {
                my $formatted_id = $self->format_hpo_id($matches->[0]->{label});
                return {
                    id    => $formatted_id,
                    label => $matches->[0]->{payload} // $term
                };
            }
        }
        return { id => "HP:0000118", label => $term };
    })->catch(sub {
        my $err = shift;
        app->log->warn("Vectorstore retrieval failed for '$term': $err");
        return { id => "HP:0000118", label => $term };
    });
};

# =========================================================
# CHUNK-WISE STRUCTURED LLM EXTRACTION UTILITY (RECOVERY IMPLEMENTED)
# =========================================================
# =========================================================
# CHUNK-WISE STRUCTURED LLM EXTRACTION UTILITY (RECOVERY IMPLEMENTED)
# =========================================================
helper extract_structured_data_async => sub {
    my ($self, $text, $schema, $system_instruction, $user_prompt, $client_model) = @_;

    my $chunks = create_document_chunks($text, 3500);
    my $merged_extracted = {};

    my $active_model    = $client_model // $model;
    my $active_endpoint = $endpoint;
    my $headers         = { 'Authorization' => "Bearer $api_key", 'Content-Type' => 'application/json' };
    my $is_local_provider = 0;

    if (($client_model && $client_model =~ /gemma|ollama/i) || $llm_provider eq 'ollama') {
        $active_endpoint = $ENV{OLLAMA_ENDPOINT} // 'http://localhost:11434/v1/chat/completions';
        $active_model    = $client_model // $ollama_model;
        $headers         = { 'Content-Type' => 'application/json' };
        $is_local_provider = 1;
    }

    my $process_chunk;
    $process_chunk = sub {
        my $chunk_idx = shift;

        if ($chunk_idx >= @$chunks) {
            $self->app->log->info("[Backend] Completed extraction processing of all chunks.");
            return Mojo::Promise->resolve($merged_extracted);
        }

        my $chunk_text = $chunks->[$chunk_idx];

        my $api_payload = {
            model       => $active_model,
            messages    => [
            { role => 'system', content => $system_instruction },
            { role => 'user',   content => "CHUNK INPUT TEXT:\n---\n$chunk_text\n---\nPrompt: $user_prompt" }
            ],
            temperature => 0.0,
        };

        # Adjust the payload format dynamically based on the model provider
        if ($is_local_provider) {
            # Local Ollama works much more reliably with general JSON mode than complex json_schema payloads
            $self->app->log->debug("[Backend] Local model provider detected. Using standardized JSON Mode.");
            $api_payload->{response_format} = { type => 'json' };
        } else {
            $api_payload->{response_format} = {
                type => 'json_schema',
                json_schema => {
                    name => "structured_extraction",
                    strict => \1,
                    schema => $schema
                }
            };
        }

        $self->app->log->debug("[Backend] Dispatching Chunk $chunk_idx to Model '$active_model' via endpoint '$active_endpoint'...");

        return $ua->post_p($active_endpoint => $headers => json => $api_payload)->then(sub {
            my $tx_call = shift;
            if ($tx_call->result && $tx_call->result->is_success) {
                my $content = $tx_call->result->json('/choices/0/message/content') // $tx_call->result->body // '';

                # Detailed diagnostic logging of the raw LLM response
                $self->app->log->debug("[Backend] Raw response from LLM (first 500 characters):\n" . substr($content, 0, 500) . "...");

                # Robust JSON Recovery
                my $parsed = clean_and_parse_json($content);

                if ($parsed) {
                    $self->app->log->debug("[Backend] Successfully parsed target structured JSON for chunk $chunk_idx.");
                    merge_extracted_structures($merged_extracted, $parsed, $schema);
                } else {
                    $self->app->log->error("[Backend] JSON Parser failed to extract a clean structure. Raw string content:\n$content");
                }
            } else {
                my $err_msg = $tx_call->error ? $tx_call->error->{message} : "Endpoint communication failed";
                my $status  = $tx_call->result ? $tx_call->result->code : "No HTTP Status";
                $self->app->log->error("[Backend] LLM API Request Failure (Status: $status): $err_msg");
                if ($tx_call->result) {
                    $self->app->log->debug("[Backend] Error response body from upstream server: " . $tx_call->result->body);
                }
            }

            return $process_chunk->($chunk_idx + 1);
        });
    };

    return $process_chunk->(0);
};

# =========================================================
# EXTRACTION ENDPOINTS
# =========================================================

post '/DBB/extract_phenopacket' => sub {
    my $c = shift;

    $c->inactivity_timeout(300);

    my $payload = $c->req->json;
    my $text_content   = $payload->{medical_report} // $payload->{report} // '';
    my $selected_model = $payload->{model};

    unless ($text_content) {
        return $c->render(json => { error => "Missing 'medical_report' or 'report' payload parameter." }, status => 400);
    }

    $c->render_later;

    # Explicit JSON structure prompt enforcement for models operating under general JSON mode fallbacks
    my $sys_instruction = "You are an expert medical entity extraction assistant. "
    . "Your job is to extract patient phenotype abnormalities, severities, onsets, and individual phenotypic modifiers strictly conforming to the requested schema. "
    . "You must output raw JSON ONLY matching the following schema keys: { phenotypicFeatures: [ { type: { label: '...' } } ] }. "
    . "Do not write any introductory text, explanation, or markdown backticks outside of the raw JSON payload.";

    my $user_prompt     = "Analyze the patient clinical description and extract the exact phenotypic structures.";

    $c->extract_structured_data_async($text_content, $phenotypic_features_schema, $sys_instruction, $user_prompt, $selected_model)->then(sub {
        my $extracted_data = shift;
        my $raw_features = $extracted_data->{phenotypicFeatures} // [];

        my @feature_promises;

        foreach my $raw_feat (@$raw_features) {
            next unless $raw_feat->{type} && $raw_feat->{type}{label};

            my $feat_promise = $c->map_to_hpo_async($raw_feat->{type}{label}, 0)->then(sub {
                my $mapped_type = shift;

                my $mapped_feature = {
                    type    => $mapped_type,
                    exclude => $raw_feat->{exclude} ? \1 : \0
                };

                my @sub_promises;

                if (my $sev_label = $raw_feat->{severity}{label}) {
                    push @sub_promises, $c->map_to_hpo_async($sev_label, 1)->then(sub {
                        $mapped_feature->{severity} = shift;
                    });
                }

                if (my $ons_label = $raw_feat->{onset}{ontologyClass}{label}) {
                    push @sub_promises, $c->map_to_hpo_async($ons_label, 1)->then(sub {
                        $mapped_feature->{onset} = { ontologyClass => shift };
                    });
                }

                if (my $mods = $raw_feat->{modifiers}) {
                    $mapped_feature->{modifiers} = [];
                    foreach my $mod (@$mods) {
                        if (my $mod_label = $mod->{label}) {
                            push @sub_promises, $c->map_to_hpo_async($mod_label, 1)->then(sub {
                                push @{$mapped_feature->{modifiers}}, shift;
                            });
                        }
                    }
                }

                @sub_promises = grep { defined $_ } @sub_promises;

                if (@sub_promises) {
                    return Mojo::Promise->all(@sub_promises)->then(sub {
                        return $mapped_feature;
                    });
                } else {
                    return Mojo::Promise->resolve($mapped_feature);
                }
            });

            push @feature_promises, $feat_promise;
        }

        @feature_promises = grep { defined $_ } @feature_promises;

        if (!@feature_promises) {
            $c->app->log->warn("[Backend] Extraction complete, but zero valid phenotypic characteristics were structured.");
            return unless $c->tx && !$c->tx->is_finished;
            return $c->render(json => {
                error => "No phenotypic features identified during pipeline execution.",
                details => "The model response did not contain the expected structure or terms. Please check server log for output diagnostics."
            }, status => 400);
        }

        return Mojo::Promise->all(@feature_promises)->then(sub {
            my @final_features = map { $_->[0] } @_;
            my $timestamp = strftime("%Y-%m-%dT%H:%M:%SZ", gmtime);

            my $phenopacket = {
                id => "phenopacket-" . time(),
                subject => {
                    id => "anonymous-patient",
                    taxonomy => {
                        id => "NCBITaxon:9606",
                        label => "homo sapiens"
                    }
                },
                phenotypicFeatures => \@final_features,
                metaData => {
                    created => $timestamp,
                    createdBy => "OntoMan",
                    phenopacketSchemaVersion => "2.0.0",
                    resources => [
                    {
                        id => "hp",
                        name => "human phenotype ontology",
                        url => "http://purl.obolibrary.org/obo/hp.owl",
                        version => "2023-10-09",
                        namespacePrefix => "HP",
                        iriPrefix => "http://purl.obolibrary.org/obo/HP_"
                    }
                    ]
                }
            };

            if ($c->tx && !$c->tx->is_finished) {
                $c->render(json => $phenopacket);
            }
        });
    })->catch(sub {
        my $err = shift;
        $c->app->log->error("Error during Phenopacket Generation: $err");
        if ($c->tx && !$c->tx->is_finished) {
            $c->render(json => { error => "Pipeline failure", details => "$err" }, status => 500);
        }
    });
};

post '/DBB/extract_icd10' => sub {
    my $c = shift;
    $c->inactivity_timeout(300);

    my $payload = $c->req->json;
    my $text_content   = $payload->{medical_report} // $payload->{report} // '';
    my $selected_model = $payload->{model};

    unless ($text_content) {
        return $c->render(json => { error => "Missing 'report' payload parameter." }, status => 400);
    }

    $c->render_later;

    my $sys_instruction = "You are an expert clinical coding assistant. Your task is to analyze medical notes and extract all primary diagnoses alongside their standard ICD-10 diagnostic codes and descriptions. Output raw JSON matches only.";
    my $user_prompt     = "Analyze the medical document and extract all diagnostics and clinical classifications.";

    $c->extract_structured_data_async($text_content, $icd10_schema, $sys_instruction, $user_prompt, $selected_model)->then(sub {
        my $extracted_data = shift;
        my $diagnoses_list = $extracted_data->{diagnoses} // [];

        if ($c->tx && !$c->tx->is_finished) {
            $c->render(json => $diagnoses_list);
        }
    })->catch(sub {
        my $err = shift;
        $c->app->log->error("Error during ICD-10 Extraction: $err");
        if ($c->tx && !$c->tx->is_finished) {
            $c->render(json => { error => "Pipeline failure", details => "$err" }, status => 500);
        }
    });
};

# =========================================================
# STANDARD DATABASE & SEARCH ENDPOINTS
# =========================================================

get '/DBB/hpo/search/:query' => sub {
    my $self = shift;
    my $query = $self->param('query');
    my $name_only = $self->param('nameOnly') || '0';

    my $base_where;
    my @bind_params;

    if ($query =~ /^hp:0*(\d+)$/i) {
        my $numeric_id = $1;
        $base_where = "WHERE t.id = ?";
        @bind_params = ($numeric_id);
    }
    else {
        my $search_term = "%$query%";
        $base_where = "WHERE t.label ILIKE ?";
        @bind_params = ($search_term);

        if ($name_only eq 'false' || $name_only eq '0') {
            $base_where = "WHERE t.label ILIKE ? OR t.definition ILIKE ? OR EXISTS (SELECT 1 FROM public.synonyms s WHERE s.idterm = t.id AND s.label ILIKE ?)";
            push @bind_params, $search_term, $search_term;
        }
    }

    my $sql = qq{
        WITH RECURSIVE search_tree AS (
        SELECT t.id as match_id, t.id as current_id, ARRAY[t.id] as path
        FROM public.terms t
        $base_where

        UNION ALL

        SELECT st.match_id, i.idparent as current_id, i.idparent || st.path
        FROM search_tree st
        JOIN public.isas i ON st.current_id = i.idchild
        )
        SELECT DISTINCT ON (match_id) match_id, path
        FROM search_tree
        ORDER BY match_id, array_length(path, 1) DESC
    };

    my $sth = $self->db->prepare($sql);
    $sth->execute(@bind_params);

    my $results = $sth->fetchall_arrayref({});

    foreach my $row (@$results) {
        if ($row->{path} =~ /^\{(.*)\}$/) {
            my @path_array = split(',', $1);
            $row->{path} = \@path_array;
        }
    }

    $self->render(json => $results);
};

helper fetchFromTable => sub {
    my ($self, $table, $sessionid, $where)=@_;
    my $sql = SQL::Abstract::More->new;
    my $order_by=[];

    if (1 || $sessionid) {
        $table = 'thai_filtered' if $table eq 'thai_project';
        my @cols=qw/*/;
        my($stmt, @bind) = $sql->select( -columns => [-distinct => @cols], -from => $table, -where=> $where, -order_by=> $order_by);
        my $sth = $self->db->prepare($stmt);
        $sth->execute(@bind);

        return $sth->fetchall_arrayref({});
    }

    return [];
};

get '/DBB/hpo/roots' => sub {
    my $self = shift;
    my $sql = q{
        SELECT t.id, t.label, t.definition,
        (CASE WHEN EXISTS (SELECT 1 FROM public.isas WHERE idparent = t.id) THEN 0 ELSE 1 END) as is_leaf
        FROM public.terms t
        WHERE t.id in (SELECT idparent FROM public.isas )
        order by 2
    };
    my $sth = $self->db->prepare($sql);
    $sth->execute();

    $self->render(json => $sth->fetchall_arrayref({}));
};

get '/DBB/hpo/children/:id' => [id => qr/.+/] => sub {
    my $self = shift;
    my $id = $self->param('id');
    my $sql = q{
        SELECT t.id, t.label,  t.definition,
        (CASE WHEN EXISTS (SELECT 1 FROM public.isas WHERE idparent = t.id) THEN 0 ELSE 1 END) as is_leaf
        FROM public.terms t
        JOIN public.isas i ON t.id = i.idchild
        WHERE i.idparent = ?
        ORDER BY t.label
    };
    my $sth = $self->db->prepare($sql);
    $sth->execute($id);

    $self->render(json => $sth->fetchall_arrayref({}));
};

get '/DBB/children/idparent/:pk' => [pk=>qr/[0-9]+/] => sub {
    my $self = shift;
    my $pk  = $self->param('pk');

    my $sql=qq{ select distinct terms.id, terms.label, terms.definition from all_childen_of(?) a join terms on terms.id = a.identity };
    my $sth = $self->db->prepare( $sql );
    $sth->execute(($pk));

    $self->render(json => $sth->fetchall_arrayref({}));
};

get '/DBB/hpo/synonyms/:id' => [id => qr/.+/] => sub {
    my $self = shift;
    my $id = $self->param('id');
    my $sql = q{ SELECT distinct idterm, label FROM public.synonyms WHERE idterm = ? ORDER BY label };
    my $sth = $self->db->prepare($sql);
    $sth->execute($id);

    $self->render(json => $sth->fetchall_arrayref({}));
};

get '/DBB/hpo/xrefs/:id' => [id => qr/.+/] => sub {
    my $self = shift;
    my $id = $self->param('id');
    my $sql = q{
        SELECT distinct idterm, label
        FROM public.xrefs
        WHERE idterm = ?
        AND label NOT LIKE 'property_value%'
        AND label NOT LIKE 'created_by%'
        AND label NOT LIKE 'terms:%'
        ORDER BY label
    };
    my $sth = $self->db->prepare($sql);
    $sth->execute($id);

    $self->render(json => $sth->fetchall_arrayref({}));
};

get '/DBB/:table'=> sub {
    my $self = shift;
    my $table  = $self->param('table');
    my $sessionid  = $self->param('session');

    my $res = $self->fetchFromTable($table, $sessionid, {});
    $self->render( json => $res);
};

get '/DBB/:table/:col/:pk' => [col=>qr/[a-z_0-9\s]+/, pk=>qr/[a-z0-9\s\-_\.]+/i] => sub {
    my $self = shift;
    my $table  = $self->param('table');
    my $pk  = $self->param('pk');
    my $col  = $self->param('col');
    my $sessionid  = $self->param('session');
    my $res=$self->fetchFromTable($table, $sessionid, {$col=> $pk});

    $self->render( json => $res);
};

put '/DBB/:table/:pk/:key'=> [key=>qr/\d+/] => sub {
    my $self    = shift;
    my $table    = $self->param('table');
    my $pk        = $self->param('pk');
    my $key        = $self->param('key');
    my $sql        = SQL::Abstract->new;

    my $ret;
    if($table ne 'documents' && $self->req->body) {
        my $jsonR   = decode_json( $self->req->body || '{}');
        my($stmt, @bind) = $sql->update($table, $jsonR, {$pk=>$key});
        my $sth = $self->db->prepare($stmt);
        $sth->execute(@bind);
        $ret={err=> $DBI::errstr};
    }
    $self->render( json=> $ret);
};

post '/DBB/:table/:pk'=> sub {
    my $self    = shift;
    my $table    = $self->param('table');
    my $pk        = $self->param('pk');
    my $sql = SQL::Abstract->new;
    my $jsonR   = decode_json( $self->req->body  || '{"name":"New"}' );

    my($stmt, @bind) = $sql->insert( $table, $jsonR);
    my $sth = $self->db->prepare($stmt);
    $sth->execute(@bind);
    my $valpk= $self->db->last_insert_id(undef, undef, $table, $pk);

    $self->render( json=>{err=> $DBI::errstr, pk => $valpk} );
};

del '/DBB/:table/:pk/:key'=> [key=>qr/\d+/] => sub {
    my $self  = shift;
    my $table = $self->param('table');
    my $pk    = $self->param('pk');
    my $key   = $self->param('key');
    my $sql   = SQL::Abstract->new;

    my($stmt, @bind) = $sql->delete($table, {$pk=>$key});
    my $sth = $self->db->prepare($stmt);
    $sth->execute(@bind);

    $self->render( json=>{err=> $DBI::errstr} );
};

# Start configuration on Port 3026
app->config(hypnotoad => {listen => ['http://*:3026'], workers => 3, heartbeat_timeout=>120, inactivity_timeout=> 120});
app->start;
