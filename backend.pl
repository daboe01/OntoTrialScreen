#!/usr/bin/env perl

# HPO Backend - Upgraded with Native Tool Use, Hierarchical JSON Schema, Chunking & Dynamic LLM Routing
use Mojolicious::Lite;
use Mojolicious::Plugin::Database;
use SQL::Abstract;
use SQL::Abstract::More;
use Data::Dumper;
use Mojo::UserAgent;
use Apache::Session::File;
use Encode;
use Mojo::JSON qw(decode_json encode_json from_json to_json);
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
my $hierarchical_group_schema = {
    type => 'object',
    properties => {
        combinationMethod => { type => 'string', enum => ['all-of', 'any-of'] },
        characteristics => {
            type => 'array',
            items => {
                type => 'object',
                properties => {
                    symptom => {
                        type => 'object',
                        properties => {
                            label => { type => 'string', description => 'Standard clinical name of the symptom or phenotypic feature' },
                            exclude => { type => 'boolean', description => 'true if listed under Exclusion Criteria (Must NOT be present), false if listed under Inclusion Criteria (Must be present).' }
                        },
                        required => ['label', 'exclude'],
                        additionalProperties => \0
                    },
                    subgroup => {
                        type => 'object',
                        properties => {
                            combinationMethod => { type => 'string', enum => ['all-of', 'any-of'] },
                            characteristics => {
                                type => 'array',
                                items => {
                                    type => 'object',
                                    properties => {
                                        symptom => {
                                            type => 'object',
                                            properties => {
                                                label => { type => 'string' },
                                                exclude => { type => 'boolean' }
                                            },
                                            required => ['label', 'exclude'],
                                            additionalProperties => \0
                                        }
                                    },
                                    required => ['symptom'],
                                    additionalProperties => \0
                                }
                            }
                        },
                        required => ['combinationMethod', 'characteristics'],
                        additionalProperties => \0
                    }
                },
                additionalProperties => \0
            }
        }
    },
    required => ['combinationMethod', 'characteristics'],
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
# Robust JSON extraction block parser to recover nested structures from narrative chat responses
sub clean_and_parse_json {
    my ($raw_content) = @_;
    return unless defined $raw_content;

    # Pre-process: Double-escape raw backslashes that are not valid JSON escape sequences (e.g., LaTeX \le, \ge, \pm)
    $raw_content =~ s/\\(?!["\\\/bfnrt]|u[0-9a-fA-F]{4})/\\\\/g;

    # 1. Straightforward deserialization check (handles decoded characters first, then falls back to raw bytes)
    my $data = eval { from_json($raw_content) } // eval { decode_json($raw_content) };
    return $data if $data;

    # 2. Extract from standard Markdown blocks
    if ($raw_content =~ /^\s*```(?:json)?\s*(.*?)\s*```/is) {
        my $inner = $1;
        $inner =~ s/\\(?!["\\\/bfnrt]|u[0-9a-fA-F]{4})/\\\\/g;
        $data = eval { from_json($inner) } // eval { decode_json($inner) };
        return $data if $data;
    }

    # 3. Aggressive extraction searching for first '{' and last '}' (with multi-line safety)
    if ($raw_content =~ /(\{.*\})/s) {
        my $inner = $1;
        $inner =~ s/\\(?!["\\\/bfnrt]|u[0-9a-fA-F]{4})/\\\\/g;
        $data = eval { from_json($inner) } // eval { decode_json($inner) };
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

# Normalizes alternative JSON designs generated by unstructured local LLMs to the expected hierarchical schema
sub normalize_to_hierarchical_schema {
    my ($raw) = @_;
    return unless ref $raw eq 'HASH';

    # If already aligned with the target schema, return as is
    if (exists $raw->{characteristics} && ref $raw->{characteristics} eq 'ARRAY') {
        return $raw;
    }

    my $normalized = {
        combinationMethod => $raw->{combinationMethod} // 'all-of',
        characteristics => []
    };

    # Match common local model variations (e.g., Gemma's phenotypic_features)
    if (exists $raw->{phenotypic_features} && ref $raw->{phenotypic_features} eq 'ARRAY') {
        foreach my $group_item (@{$raw->{phenotypic_features}}) {
            my $group_exclude = ($group_item->{exclude} || ($group_item->{name} && $group_item->{name} =~ /exclusion/i)) ? 1 : 0;
            my $group_logic = $group_item->{logic} // $group_item->{combinationMethod} // 'all-of';
            $group_logic = ($group_logic =~ /any/i) ? 'any-of' : 'all-of';

            my $subgroup = {
                combinationMethod => $group_logic,
                characteristics => []
            };

            # Handle nested subgroups
            if (exists $group_item->{subgroups} && ref $group_item->{subgroups} eq 'ARRAY') {
                foreach my $sub (@{$group_item->{subgroups}}) {
                    my $sub_logic = $sub->{logic} // $sub->{combinationMethod} // 'all-of';
                    $sub_logic = ($sub_logic =~ /any/i) ? 'any-of' : 'all-of';

                    my $nested_sub = {
                        combinationMethod => $sub_logic,
                        characteristics => []
                    };

                    if (exists $sub->{features} && ref $sub->{features} eq 'ARRAY') {
                        foreach my $feat (@{$sub->{features}}) {
                            push @{$nested_sub->{characteristics}}, {
                                symptom => {
                                    label => $feat,
                                    exclude => $group_exclude ? \1 : \0
                                }
                            };
                        }
                    }
                    push @{$subgroup->{characteristics}}, { subgroup => $nested_sub } if @{$nested_sub->{characteristics}};
                }
            }

            # Handle flat features inside the parent group item
            if (exists $group_item->{features} && ref $group_item->{features} eq 'ARRAY') {
                foreach my $feat (@{$group_item->{features}}) {
                    push @{$subgroup->{characteristics}}, {
                        symptom => {
                            label => $feat,
                            exclude => $group_exclude ? \1 : \0
                        }
                    };
                }
            }

            if (@{$subgroup->{characteristics}}) {
                push @{$normalized->{characteristics}}, { subgroup => $subgroup };
            }
        }
    }

    return $normalized;
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
# RECURSIVE ASYNCHRONOUS HPO MAPPER HELPER
# =========================================================
helper map_hierarchical_group_async => sub {
    my ($self, $group) = @_;
    return Mojo::Promise->resolve(undef) unless ref $group eq 'HASH';

    my $combination_method = $group->{combinationMethod} // 'all-of';
    my $characteristics    = $group->{characteristics}    // [];

    my @promises;
    my $mapped_characteristics = [];

    foreach my $char (@$characteristics) {
        if (my $sym = $char->{symptom}) {
            my $label   = $sym->{label};
            my $exclude = $sym->{exclude} ? 1 : 0;

            my $p = $self->map_to_hpo_async($label, 0)->then(sub {
                my $mapped_hpo = shift;
                push @$mapped_characteristics, {
                    exclude => $exclude ? \1 : \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => $mapped_hpo->{id},
                            display => $mapped_hpo->{label} // $label
                        }]
                    }
                };
            });
            push @promises, $p;
        }
        elsif (my $sub = $char->{subgroup}) {
            my $p = $self->map_hierarchical_group_async($sub)->then(sub {
                my $mapped_subgroup = shift;
                push @$mapped_characteristics, $mapped_subgroup if $mapped_subgroup;
            });
            push @promises, $p;
        }
    }

    if (@promises) {
        return Mojo::Promise->all(@promises)->then(sub {
            return {
                resourceType      => "Group",
                combinationMethod => $combination_method,
                characteristic    => $mapped_characteristics
            };
        });
    } else {
        return Mojo::Promise->resolve({
            resourceType      => "Group",
            combinationMethod => $combination_method,
            characteristic    => $mapped_characteristics
        });
    }
};

# =========================================================
# CHUNK-WISE STRUCTURED LLM EXTRACTION UTILITY
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

    # Guide local models by appending the JSON schema design to the system instruction
    my $effective_sys_instruction = $system_instruction;
    if ($is_local_provider) {
        my $schema_json = encode_json($schema);
        $effective_sys_instruction .= "\n\nCRITICAL: You must format your JSON output to conform exactly to this schema:\n$schema_json\nDo not use custom keys outside of this specification.";
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
            { role => 'system', content => $effective_sys_instruction },
            { role => 'user',   content => "CHUNK INPUT TEXT:\n---\n$chunk_text\n---\nPrompt: $user_prompt" }
            ],
            temperature => 0.0,
        };

        if ($is_local_provider) {
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

                # $self->app->log->debug("[Backend] Raw response from LLM (first 500 characters):\n" . substr($content, 0, 500) . "...");
                $self->app->log->debug($content);

                my $parsed = clean_and_parse_json($content);

                if ($parsed) {
                    $self->app->log->debug("[Backend] Successfully parsed target structured JSON for chunk $chunk_idx.");

                    # Normalize deviations if local provider was used
                    if ($is_local_provider) {
                        $parsed = normalize_to_hierarchical_schema($parsed);
                    }

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

post '/DBB/extract_fhir_inex_criteria' => sub {
    my $c = shift;
    $c->inactivity_timeout(300);

    my $payload = $c->req->json;
    my $text_content   = $payload->{medical_report} // $payload->{report} // '';
    my $selected_model = $payload->{model};

    unless ($text_content) {
        return $c->render(json => { error => "Missing 'medical_report' or 'report' payload parameter." }, status => 400);
    }

    $c->render_later;

    # =========================================================
    # DEBUG-MOCK INTERVENTION
    # =========================================================
    if (defined $selected_model && $selected_model eq 'mock-extractor') {
        $c->app->log->debug("[Backend] Model 'mock-extractor' detected. Bypassing LLM execution and returning mock structured JSON...");

        my $mock_data = {
            combinationMethod => "all-of",
            characteristics => [
            {
                subgroup => {
                    combinationMethod => "all-of",
                    characteristics => [
                    {
                        subgroup => {
                            combinationMethod => "all-of",
                            characteristics => [
                            {
                                symptom => {
                                    label => "Keratoconjunctivitis Sicca (Dry Eye Disease)",
                                    exclude => \0 # Mojo JSON boolean false
                                }
                            },
                            {
                                symptom => {
                                    label => "Corneal epithelial erosion or punctate keratitis",
                                    exclude => \0
                                }
                            }
                            ]
                        }
                    },
                    {
                        subgroup => {
                            combinationMethod => "any-of",
                            characteristics => [
                            {
                                symptom => {
                                    label => "Severe ocular discomfort",
                                    exclude => \0
                                }
                            },
                            {
                                symptom => {
                                    label => "Foreign body sensation",
                                    exclude => \0
                                }
                            },
                            {
                                symptom => {
                                    label => "Persistent ocular burning",
                                    exclude => \0
                                }
                            }
                            ]
                        }
                    },
                    {
                        subgroup => {
                            combinationMethod => "all-of",
                            characteristics => [
                            {
                                symptom => {
                                    label => "Decreased tear production (Schirmer's I \\le 10 mm/5 minutes)",
                                    exclude => \0
                                }
                            }
                            ]
                        }
                    }
                    ]
                }
            },
            {
                subgroup => {
                    combinationMethod => "any-of",
                    characteristics => [
                    {
                        symptom => {
                            label => "Active ocular infection (bacterial conjunctivitis, keratitis, or blepharitis)",
                            exclude => \1 # Mojo JSON boolean true
                        }
                    },
                    {
                        symptom => {
                            label => "History of refractive corneal surgery within the past 180 days",
                            exclude => \1
                        }
                    },
                    {
                        symptom => {
                            label => "Secondary Sjögren's syndrome",
                            exclude => \1
                        }
                    },
                    {
                        symptom => {
                            label => "Active ocular allergy",
                            exclude => \1
                        }
                    }
                    ]
                }
            }
            ]
        };

        # Übergebe die Mock-Daten an die HPO-Asynchron-Mapping Pipeline
        return $c->map_hierarchical_group_async($mock_data)->then(sub {
            my $mapped_group = shift;
            if ($c->tx && !$c->tx->is_finished) {
                $c->render(json => $mapped_group);
            }
        })->catch(sub {
            my $err = shift;
            $c->app->log->error("Error mapping mock group: $err");
            if ($c->tx && !$c->tx->is_finished) {
                $c->render(json => { error => "Mock pipeline failure", details => "$err" }, status => 500);
            }
        });
    }

    # =========================================================
    # REALE LLM EXTRAKTION (PRODUKTIV-PFAD)
    # =========================================================
    my $sys_instruction = "You are an expert medical entity extraction assistant. "
    . "Your job is to analyze the patient clinical synopsis and extract patient phenotypic features into a logical nested group structure. "
    . "Group the clinical symptoms into logical blocks using 'all-of' (AND) and 'any-of' (OR) relationships. "
    . "Set the 'exclude' flag to true for symptoms listed under Exclusion Criteria (must NOT be present), and to false for symptoms listed under Inclusion Criteria. "
    . "You must output raw JSON ONLY conforming strictly to the requested schema. "
    . "Do not write any introductory text, explanation, or markdown backticks outside of the raw JSON payload.";

    my $user_prompt = "Analyze the study protocol text, identify the inclusion/exclusion requirements, group them logically into subgroups, and extract nested criteria accordingly.";

    $c->extract_structured_data_async($text_content, $hierarchical_group_schema, $sys_instruction, $user_prompt, $selected_model)->then(sub {
        my $extracted_data = shift;

        return $c->map_hierarchical_group_async($extracted_data)->then(sub {
            my $mapped_group = shift;
            if ($c->tx && !$c->tx->is_finished) {
                $c->render(json => $mapped_group);
            }
        });
    })->catch(sub {
        my $err = shift;
        $c->app->log->error("Error during FHIR Group Generation: $err");
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
