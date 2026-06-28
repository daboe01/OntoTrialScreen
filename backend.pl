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
                            labels => {
                                type => 'array',
                                items => { type => 'string' },
                                description => 'The primary phenotypic symptom standard name and its clinical modifiers.'
                            },
                            exclude => { type => 'boolean', description => 'true if listed under Exclusion Criteria (Must NOT be present), false if listed under Inclusion Criteria.' },
                            combinationMethod => { type => 'string', enum => ['all-of', 'any-of', 'neither-of'] }
                        },
                        required => ['labels', 'exclude', 'combinationMethod'],
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
                                                labels => { type => 'array', items => { type => 'string' } },
                                                exclude => { type => 'boolean' },
                                                combinationMethod => { type => 'string', enum => ['all-of', 'any-of', 'neither-of'] }
                                            },
                                            required => ['labels', 'exclude', 'combinationMethod'],
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

# Normalizes symptom nodes inside alternative JSON layouts to expected schemas
sub normalize_symptom_node {
    my ($sym) = @_;
    return unless ref $sym eq 'HASH';

    if (exists $sym->{label} && !exists $sym->{labels}) {
        $sym->{labels} = [ delete $sym->{label} ];
    }
    $sym->{labels} //= [];
    if (ref $sym->{labels} ne 'ARRAY') {
        $sym->{labels} = [ $sym->{labels} ];
    }

    my $raw_exclude = $sym->{exclude};
    my $is_exclude = (ref $raw_exclude ? $$raw_exclude : $raw_exclude) ? 1 : 0;
    $sym->{exclude} = $is_exclude ? \1 : \0;

    if (!exists $sym->{combinationMethod}) {
        $sym->{combinationMethod} = $is_exclude ? 'neither-of' : 'all-of';
    }
}

# Recursively scans subgroups to normalize alternative schemas
sub normalize_subgroup_node {
    my ($sub) = @_;
    return unless ref $sub eq 'HASH';

    $sub->{combinationMethod} //= 'all-of';
    if (exists $sub->{characteristics} && ref $sub->{characteristics} eq 'ARRAY') {
        foreach my $char (@{$sub->{characteristics}}) {
            if (exists $char->{symptom}) {
                normalize_symptom_node($char->{symptom});
            } elsif (exists $char->{subgroup}) {
                normalize_subgroup_node($char->{subgroup});
            }
        }
    }
}

# Normalizes alternative JSON designs generated by unstructured local LLMs to the expected hierarchical schema
sub normalize_to_hierarchical_schema {
    my ($raw) = @_;
    return unless ref $raw eq 'HASH';

    if (exists $raw->{characteristics} && ref $raw->{characteristics} eq 'ARRAY') {
        normalize_subgroup_node($raw);
        return $raw;
    }

    my $normalized = {
        combinationMethod => $raw->{combinationMethod} // 'all-of',
        characteristics => []
    };

    if (exists $raw->{phenotypic_features} && ref $raw->{phenotypic_features} eq 'ARRAY') {
        foreach my $group_item (@{$raw->{phenotypic_features}}) {
            my $raw_exclude = $group_item->{exclude};

            # Safe dereference of boolean fields
            my $is_exclude_true = (ref $raw_exclude ? $$raw_exclude : $raw_exclude) ? 1 : 0;
            my $group_exclude = ($is_exclude_true || ($group_item->{name} && $group_item->{name} =~ /exclusion/i)) ? 1 : 0;

            my $group_logic = $group_item->{logic} // $group_item->{combinationMethod} // 'all-of';
            $group_logic = ($group_logic =~ /any/i) ? 'any-of' : 'all-of';

            my $subgroup = {
                combinationMethod => $group_logic,
                characteristics => []
            };

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
                                    labels => [$feat],
                                    exclude => $group_exclude ? \1 : \0,
                                    combinationMethod => $group_exclude ? 'neither-of' : 'all-of'
                                }
                            };
                        }
                    }
                    push @{$subgroup->{characteristics}}, { subgroup => $nested_sub } if @{$nested_sub->{characteristics}};
                }
            }

            if (exists $group_item->{features} && ref $group_item->{features} eq 'ARRAY') {
                foreach my $feat (@{$group_item->{features}}) {
                    push @{$subgroup->{characteristics}}, {
                        symptom => {
                            labels => [$feat],
                            exclude => $group_exclude ? \1 : \0,
                            combinationMethod => $group_exclude ? 'neither-of' : 'all-of'
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

# Recursively scans extracted structure to guarantee that pure exclusion subgroups are assigned 'all-of'
sub enforce_exclusion_subgroup_logic {
    my ($group) = @_;
    return unless ref $group eq 'HASH';

    my $characteristics = $group->{characteristics} // [];
    my $has_exclusions = 0;
    my $has_inclusions = 0;

    foreach my $char (@$characteristics) {
        if (exists $char->{symptom}) {
            my $ex = $char->{symptom}{exclude};
            my $is_exclude = (ref $ex ? $$ex : $ex) ? 1 : 0;
            if ($is_exclude) {
                $has_exclusions = 1;
            } else {
                $has_inclusions = 1;
            }
        }
        elsif (exists $char->{subgroup}) {
            enforce_exclusion_subgroup_logic($char->{subgroup});
            if (subgroup_has_exclusions($char->{subgroup})) {
                $has_exclusions = 1;
            }
        }
    }

    if ($has_exclusions && !$has_inclusions) {
        $group->{combinationMethod} = 'all-of';
    }
}

# Helper to verify if a subgroup contains exclusion flags
sub subgroup_has_exclusions {
    my ($group) = @_;
    return 0 unless ref $group eq 'HASH';
    my $characteristics = $group->{characteristics} // [];
    foreach my $char (@$characteristics) {
        if (exists $char->{symptom}) {
            my $ex = $char->{symptom}{exclude};
            return 1 if (ref $ex ? $$ex : $ex);
        }
        elsif (exists $char->{subgroup}) {
            return 1 if subgroup_has_exclusions($char->{subgroup});
        }
    }
    return 0;
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
# COGNITIVE SPLITTING (PHENOTYPES & MODIFIERS)
# =========================================================

# Helper to split clinical strings into phenotypes and modifiers asynchronously
helper split_symptom_components_async => sub {
    my ($self, $term, $client_model) = @_;
    return Mojo::Promise->resolve({ phenotype => $term, modifiers => [] }) unless $term;

    my $sys_instruction = "You are a clinical NLP assistant. Your job is to analyze a phenotypic feature description and split it into its core phenotype (the main disease, sign, or symptom) and any associated modifiers (such as clinical descriptors, severity, onset, localization, or temporal terms). Output raw JSON conforming strictly to the schema.";
    my $user_prompt     = "Analyze and split this clinical feature: '$term'";

    my $split_schema = {
        type => 'object',
        properties => {
            phenotype => { type => 'string', description => 'The core clinical phenotype or symptom term' },
            modifiers => {
                type => 'array',
                items => { type => 'string' },
                description => 'Any clinical modifiers, severity descriptors, temporal terms, or localization terms'
            }
        },
        required => ['phenotype', 'modifiers'],
        additionalProperties => \0
    };

    return $self->extract_structured_data_async($term, $split_schema, $sys_instruction, $user_prompt, $client_model)->then(sub {
        my $result = shift;
        if (ref $result eq 'HASH' && defined $result->{phenotype}) {
            return $result;
        }
        return { phenotype => $term, modifiers => [] };
    })->catch(sub {
        return { phenotype => $term, modifiers => [] };
    });
};

# Helper to recursively parse and split terms inside extracted group structures
helper split_hierarchical_group_async => sub {
    my ($self, $group, $client_model) = @_;
    return Mojo::Promise->resolve(undef) unless ref $group eq 'HASH';

    my $characteristics = $group->{characteristics} // [];
    my @promises;

    for (my $i = 0; $i < @$characteristics; $i++) {
        my $char = $characteristics->[$i];

        if (my $sym = $char->{symptom}) {
            my $labels = $sym->{labels} // ($sym->{label} ? [$sym->{label}] : []);
            my $exclude = $sym->{exclude};
            my $index = $i;

            my @split_promises;
            foreach my $lbl (@$labels) {
                push @split_promises, $self->split_symptom_components_async($lbl, $client_model);
            }

            my $p = Mojo::Promise->all(@split_promises)->then(sub {
                my @splits = @_;
                my @phenotypes;
                my @modifiers;
                foreach my $s_res (@splits) {
                    my $res = $s_res->[0];
                    if ($res && ref $res eq 'HASH') {
                        push @phenotypes, $res->{phenotype} if $res->{phenotype};
                        push @modifiers, @{$res->{modifiers} // []};
                    }
                }

                if (@modifiers) {
                    my @sub_chars;
                    foreach my $p_term (@phenotypes) {
                        push @sub_chars, {
                            symptom => {
                                labels => [$p_term],
                                exclude => \0,
                                combinationMethod => "all-of",
                                is_modifier => 0
                            }
                        };
                    }
                    foreach my $m_term (@modifiers) {
                        push @sub_chars, {
                            symptom => {
                                labels => [$m_term],
                                exclude => \0,
                                combinationMethod => "all-of",
                                is_modifier => 1
                            }
                        };
                    }

                    $characteristics->[$index] = {
                        subgroup => {
                            combinationMethod => "all-of",
                            composite_flag => 1, # Marks the subgroup as composite
                            characteristics => \@sub_chars
                        }
                    };
                } else {
                    $sym->{is_modifier} = 0;
                }
            });
            push @promises, $p;
        }
        elsif (my $sub = $char->{subgroup}) {
            my $p = $self->split_hierarchical_group_async($sub, $client_model);
            push @promises, $p;
        }
    }

    if (@promises) {
        return Mojo::Promise->all(@promises)->then(sub { return $group; });
    } else {
        return Mojo::Promise->resolve($group);
    }
};

# =========================================================
# RECURSIVE ASYNCHRONOUS HPO MAPPER HELPER (Order Preserving)
# =========================================================
helper map_hierarchical_group_async => sub {
    my ($self, $group) = @_;
    return Mojo::Promise->resolve(undef) unless ref $group eq 'HASH';

    my $combination_method = $group->{combinationMethod} // 'all-of';
    my $characteristics    = $group->{characteristics}    // [];

    my @promises;
    my @mapped_characteristics; # Pre-allocate array to preserve original indices

    for (my $i = 0; $i < @$characteristics; $i++) {
        my $char = $characteristics->[$i];

        if (my $sym = $char->{symptom}) {
            my $labels = $sym->{labels} // ($sym->{label} ? [$sym->{label}] : []);
            my $raw_exclude = $sym->{exclude};

            # Safe dereference of Mojo::JSON boolean references (\1 or \0)
            my $exclude = (ref $raw_exclude ? $$raw_exclude : $raw_exclude) ? 1 : 0;
            my $combination_method = $sym->{combinationMethod} // ($exclude ? 'neither-of' : 'all-of');
            my $is_modifier = $sym->{is_modifier} // 0; # Routed to proper modifier or core phenotype catalogs [25]

            # Strategic debug statement
            $self->app->log->debug(sprintf(
            "[DEBUG HPO Backend] Mapping element %d: labels=%s | is_modifier=%d | raw_exclude=%s | resolved_exclude=%d",
            $i + 1,
            join(', ', @$labels),
            $is_modifier,
            (defined $raw_exclude ? (ref $raw_exclude ? "ref(" . $$raw_exclude . ")" : $raw_exclude) : 'undef'),
            $exclude
            ));

            # Capture the current index in a lexical scope
            my $index = $i;
            my @label_promises;
            my @codings;

            for (my $j = 0; $j < @$labels; $j++) {
                my $lbl = $labels->[$j];
                my $lbl_idx = $j;

                my $p_lbl = $self->map_to_hpo_async($lbl, $is_modifier)->then(sub {
                    my $mapped_hpo = shift;
                    $codings[$lbl_idx] = {
                        system  => "http://human-phenotype-ontology.org",
                        code    => $mapped_hpo->{id},
                        display => $mapped_hpo->{label} // $lbl
                    };
                });
                push @label_promises, $p_lbl;
            }

            my $p;
            if (@label_promises) {
                $p = Mojo::Promise->all(@label_promises)->then(sub {
                    my @clean_codings = grep { defined } @codings;
                    $mapped_characteristics[$index] = {
                        exclude => $exclude ? \1 : \0,
                        combinationMethod => $combination_method,
                        valueCodeableConcept => {
                            coding => \@clean_codings
                        }
                    };
                });
            } else {
                $p = Mojo::Promise->resolve()->then(sub {
                    $mapped_characteristics[$index] = {
                        exclude => $exclude ? \1 : \0,
                        combinationMethod => $combination_method,
                        valueCodeableConcept => {
                            coding => []
                        }
                    };
                });
            }
            push @promises, $p;
        }
        elsif (my $sub = $char->{subgroup}) {
            my $index = $i;
            my $composite_flag = $sub->{composite_flag} // 0;

            my $p = $self->map_hierarchical_group_async($sub)->then(sub {
                my $mapped_subgroup = shift;
                if ($mapped_subgroup && $composite_flag) {
                    $mapped_subgroup->{id} = "composite-" . int(rand(1000000));
                    $mapped_subgroup->{membership} = "conceptual";
                    $mapped_subgroup->{type} = "person";
                }
                $mapped_characteristics[$index] = $mapped_subgroup if $mapped_subgroup;
            });
            push @promises, $p;
        }
    }

    if (@promises) {
        return Mojo::Promise->all(@promises)->then(sub {
            my @clean = grep { defined } @mapped_characteristics;
            return {
                resourceType      => "Group",
                combinationMethod => $combination_method,
                characteristic    => \@clean
            };
        });
    } else {
        return Mojo::Promise->resolve({
            resourceType      => "Group",
            combinationMethod => $combination_method,
            characteristic    => []
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
    # DEBUG-MOCK INTERVENTION (Multi-Token Modifiers Aligned)
    # =========================================================
    if (defined $selected_model && $selected_model eq 'mock-extractor') {
        $c->app->log->debug("[Backend] Model 'mock-extractor' detected. Bypassing LLM execution and returning mock structured JSON...");

        my $mock_data = {
            resourceType => "Group",
            combinationMethod => "all-of",
            characteristic => [
            {
                # Keratoconjunctivitis Sicca (Dry Eye Disease) - Composite Subgroup
                resourceType => "Group",
                id => "composite-mock-1",
                combinationMethod => "all-of",
                membership => "conceptual",
                type => "person",
                exclude => \0,
                characteristic => [
                {
                    exclude => \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => "HP:0001097",
                            display => "Keratoconjunctivitis Sicca"
                        }]
                    }
                },
                {
                    exclude => \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => "HP:0000118",
                            display => "Dry Eye Disease"
                        }]
                    }
                }
                ]
            },
            {
                # Corneal epithelial erosion or punctate keratitis - alternative options
                resourceType => "Group",
                combinationMethod => "any-of",
                exclude => \0,
                characteristic => [
                {
                    exclude => \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => "HP:0200147",
                            display => "corneal epithelial erosion"
                        }]
                    }
                },
                {
                    exclude => \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => "HP:0007718",
                            display => "punctate keratitis"
                        }]
                    }
                }
                ]
            },
            {
                # Severe ocular discomfort, foreign body sensation, or persistent ocular burning
                resourceType => "Group",
                combinationMethod => "any-of",
                exclude => \0,
                characteristic => [
                {
                    # Severe ocular discomfort - Composite Subgroup
                    resourceType => "Group",
                    id => "composite-mock-2",
                    combinationMethod => "all-of",
                    membership => "conceptual",
                    type => "person",
                    exclude => \0,
                    characteristic => [
                    {
                        exclude => \0,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0034333",
                                display => "ocular discomfort"
                            }]
                        }
                    },
                    {
                        exclude => \0,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0012828",
                                display => "severe"
                            }]
                        }
                    }
                    ]
                },
                {
                    exclude => \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => "HP:0034335",
                            display => "foreign body sensation"
                        }]
                    }
                },
                {
                    # Persistent ocular burning - Composite Subgroup
                    resourceType => "Group",
                    id => "composite-mock-3",
                    combinationMethod => "all-of",
                    membership => "conceptual",
                    type => "person",
                    exclude => \0,
                    characteristic => [
                    {
                        exclude => \0,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0034336",
                                display => "ocular burning"
                            }]
                        }
                    },
                    {
                        exclude => \0,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0031914",
                                display => "persistent"
                            }]
                        }
                    }
                    ]
                }
                ]
            },
            {
                # Decreased tear production - Composite Subgroup
                resourceType => "Group",
                id => "composite-mock-4",
                combinationMethod => "all-of",
                membership => "conceptual",
                type => "person",
                exclude => \0,
                characteristic => [
                {
                    exclude => \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => "HP:0000565",
                            display => "decreased tear production"
                        }]
                    }
                },
                {
                    exclude => \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => "HP:0012824",
                            display => "Schirmer's I"
                        }]
                    }
                }
                ]
            },
            {
                # Exclusion Criteria Group
                resourceType => "Group",
                combinationMethod => "all-of",
                exclude => \1,
                characteristic => [
                {
                    # Active ocular infection - Composite Subgroup
                    resourceType => "Group",
                    id => "composite-mock-5",
                    combinationMethod => "all-of",
                    membership => "conceptual",
                    type => "person",
                    exclude => \1,
                    characteristic => [
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0000598",
                                display => "ocular infection"
                            }]
                        }
                    },
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0003674",
                                display => "active"
                            }]
                        }
                    }
                    ]
                },
                {
                    # History of refractive corneal surgery - Composite Subgroup
                    resourceType => "Group",
                    id => "composite-mock-6",
                    combinationMethod => "all-of",
                    membership => "conceptual",
                    type => "person",
                    exclude => \1,
                    characteristic => [
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0032943",
                                display => "refractive corneal surgery"
                            }]
                        }
                    },
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0003577",
                                display => "history of"
                            }]
                        }
                    }
                    ]
                },
                {
                    # Secondary Sjögren's syndrome - Composite Subgroup
                    resourceType => "Group",
                    id => "composite-mock-7",
                    combinationMethod => "all-of",
                    membership => "conceptual",
                    type => "person",
                    exclude => \1,
                    characteristic => [
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0001497",
                                display => "Sjögren's syndrome"
                            }]
                        }
                    },
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0012823",
                                display => "secondary"
                            }]
                        }
                    }
                    ]
                },
                {
                    # Active ocular allergy - Composite Subgroup
                    resourceType => "Group",
                    id => "composite-mock-8",
                    combinationMethod => "all-of",
                    membership => "conceptual",
                    type => "person",
                    exclude => \1,
                    characteristic => [
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0001111",
                                display => "ocular allergy"
                            }]
                        }
                    },
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0003674",
                                display => "active"
                            }]
                        }
                    }
                    ]
                }
                ]
            }
            ]
        };

        return $c->render(json => $mock_data);
    }

    # =========================================================
    # REAL PIPELINE: EXTRACTION -> COGNITIVE SPLIT -> HPO MAP
    # =========================================================
    my $sys_instruction = "You are an expert medical entity extraction assistant. "
    . "Your task is to analyze the clinical trial synopsis and extract phenotypic features into a logical nested group structure.\n\n"
    . "LOGICAL GROUPING RULES:\n"
    . "1. MULTIPLE CODES PER SYMPTOM: For complex symptoms, list them inside the 'labels' array of the symptom.\n"
    . "2. INCLUSION VS EXCLUSION FLAGS: Set 'exclude': false and 'combinationMethod': 'all-of' or 'any-of' for symptoms listed under Inclusion Criteria. Set 'exclude': true and 'combinationMethod': 'neither-of' for symptoms listed under Exclusion Criteria.\n"
    . "3. EXCLUSION GROUPING: Group all exclusion criteria together in their own dedicated subgroup.\n"
    . "4. EXCLUSION OPERATOR (CRITICAL): Subgroups containing exclusion criteria elements ('exclude': true) MUST use 'combinationMethod': 'all-of'. "
    . "Mathematically, to reject a patient who has any of the excluded features, they must satisfy: (NOT Feature A) AND (NOT Feature B) AND (NOT Feature C). "
    . "Therefore, combining exclusion elements requires an 'all-of' combination method. Never use 'any-of' for an exclusion subgroup.\n"
    . "5. INCLUSION OPERATORS: Use 'all-of' (AND) to group mandatory inclusion criteria, and 'any-of' (OR) to group optional alternative symptoms.\n\n"
    . "You must output raw JSON ONLY conforming strictly to the requested schema. Do not write introductory text, explanations, or markdown formatting outside the JSON payload.";

    my $user_prompt = "Analyze the study protocol text, identify the inclusion/exclusion requirements, group them logically into subgroups, and extract nested criteria accordingly.";

    $c->extract_structured_data_async($text_content, $hierarchical_group_schema, $sys_instruction, $user_prompt, $selected_model)->then(sub {
        my $extracted_data = shift;

        # Step 1.5: Split core phenotypes and modifier entities recursively
        return $c->split_hierarchical_group_async($extracted_data, $selected_model)->then(sub {
            my $split_data = shift;

            # Step 2: Enforce exclusions logic
            enforce_exclusion_subgroup_logic($split_data);

            # Step 3: Run the aligned HPO mapping pipeline
            return $c->map_hierarchical_group_async($split_data)->then(sub {
                my $mapped_group = shift;
                if ($c->tx && !$c->tx->is_finished) {
                    $c->render(json => $mapped_group);
                }
            });
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
                            labels => {
                                type => 'array',
                                items => { type => 'string' },
                                description => 'The primary phenotypic symptom standard name and its clinical modifiers.'
                            },
                            exclude => { type => 'boolean', description => 'true if listed under Exclusion Criteria (Must NOT be present), false if listed under Inclusion Criteria.' },
                            combinationMethod => { type => 'string', enum => ['all-of', 'any-of', 'neither-of'] }
                        },
                        required => ['labels', 'exclude', 'combinationMethod'],
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
                                                labels => { type => 'array', items => { type => 'string' } },
                                                exclude => { type => 'boolean' },
                                                combinationMethod => { type => 'string', enum => ['all-of', 'any-of', 'neither-of'] }
                                            },
                                            required => ['labels', 'exclude', 'combinationMethod'],
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

# Normalizes symptom nodes inside alternative JSON layouts to expected schemas
sub normalize_symptom_node {
    my ($sym) = @_;
    return unless ref $sym eq 'HASH';

    if (exists $sym->{label} && !exists $sym->{labels}) {
        $sym->{labels} = [ delete $sym->{label} ];
    }
    $sym->{labels} //= [];
    if (ref $sym->{labels} ne 'ARRAY') {
        $sym->{labels} = [ $sym->{labels} ];
    }

    my $raw_exclude = $sym->{exclude};
    my $is_exclude = (ref $raw_exclude ? $$raw_exclude : $raw_exclude) ? 1 : 0;
    $sym->{exclude} = $is_exclude ? \1 : \0;

    if (!exists $sym->{combinationMethod}) {
        $sym->{combinationMethod} = $is_exclude ? 'neither-of' : 'all-of';
    }
}

# Recursively scans subgroups to normalize alternative schemas
sub normalize_subgroup_node {
    my ($sub) = @_;
    return unless ref $sub eq 'HASH';

    $sub->{combinationMethod} //= 'all-of';
    if (exists $sub->{characteristics} && ref $sub->{characteristics} eq 'ARRAY') {
        foreach my $char (@{$sub->{characteristics}}) {
            if (exists $char->{symptom}) {
                normalize_symptom_node($char->{symptom});
            } elsif (exists $char->{subgroup}) {
                normalize_subgroup_node($char->{subgroup});
            }
        }
    }
}

# Normalizes alternative JSON designs generated by unstructured local LLMs to the expected hierarchical schema
sub normalize_to_hierarchical_schema {
    my ($raw) = @_;
    return unless ref $raw eq 'HASH';

    if (exists $raw->{characteristics} && ref $raw->{characteristics} eq 'ARRAY') {
        normalize_subgroup_node($raw);
        return $raw;
    }

    my $normalized = {
        combinationMethod => $raw->{combinationMethod} // 'all-of',
        characteristics => []
    };

    if (exists $raw->{phenotypic_features} && ref $raw->{phenotypic_features} eq 'ARRAY') {
        foreach my $group_item (@{$raw->{phenotypic_features}}) {
            my $raw_exclude = $group_item->{exclude};

            # Safe dereference of boolean fields
            my $is_exclude_true = (ref $raw_exclude ? $$raw_exclude : $raw_exclude) ? 1 : 0;
            my $group_exclude = ($is_exclude_true || ($group_item->{name} && $group_item->{name} =~ /exclusion/i)) ? 1 : 0;

            my $group_logic = $group_item->{logic} // $group_item->{combinationMethod} // 'all-of';
            $group_logic = ($group_logic =~ /any/i) ? 'any-of' : 'all-of';

            my $subgroup = {
                combinationMethod => $group_logic,
                characteristics => []
            };

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
                                    labels => [$feat],
                                    exclude => $group_exclude ? \1 : \0,
                                    combinationMethod => $group_exclude ? 'neither-of' : 'all-of'
                                }
                            };
                        }
                    }
                    push @{$subgroup->{characteristics}}, { subgroup => $nested_sub } if @{$nested_sub->{characteristics}};
                }
            }

            if (exists $group_item->{features} && ref $group_item->{features} eq 'ARRAY') {
                foreach my $feat (@{$group_item->{features}}) {
                    push @{$subgroup->{characteristics}}, {
                        symptom => {
                            labels => [$feat],
                            exclude => $group_exclude ? \1 : \0,
                            combinationMethod => $group_exclude ? 'neither-of' : 'all-of'
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

# Recursively scans extracted structure to guarantee that pure exclusion subgroups are assigned 'all-of'
sub enforce_exclusion_subgroup_logic {
    my ($group) = @_;
    return unless ref $group eq 'HASH';

    my $characteristics = $group->{characteristics} // [];
    my $has_exclusions = 0;
    my $has_inclusions = 0;

    foreach my $char (@$characteristics) {
        if (exists $char->{symptom}) {
            my $ex = $char->{symptom}{exclude};
            my $is_exclude = (ref $ex ? $$ex : $ex) ? 1 : 0;
            if ($is_exclude) {
                $has_exclusions = 1;
            } else {
                $has_inclusions = 1;
            }
        }
        elsif (exists $char->{subgroup}) {
            enforce_exclusion_subgroup_logic($char->{subgroup});
            if (subgroup_has_exclusions($char->{subgroup})) {
                $has_exclusions = 1;
            }
        }
    }

    if ($has_exclusions && !$has_inclusions) {
        $group->{combinationMethod} = 'all-of';
    }
}

# Helper to verify if a subgroup contains exclusion flags
sub subgroup_has_exclusions {
    my ($group) = @_;
    return 0 unless ref $group eq 'HASH';
    my $characteristics = $group->{characteristics} // [];
    foreach my $char (@$characteristics) {
        if (exists $char->{symptom}) {
            my $ex = $char->{symptom}{exclude};
            return 1 if (ref $ex ? $$ex : $ex);
        }
        elsif (exists $char->{subgroup}) {
            return 1 if subgroup_has_exclusions($char->{subgroup});
        }
    }
    return 0;
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
# COGNITIVE SPLITTING (PHENOTYPES & MODIFIERS)
# =========================================================

# Helper to split clinical strings into phenotypes and modifiers asynchronously
helper split_symptom_components_async => sub {
    my ($self, $term, $client_model) = @_;
    return Mojo::Promise->resolve({ phenotype => $term, modifiers => [] }) unless $term;

    my $sys_instruction = "You are a clinical NLP assistant. Your job is to analyze a phenotypic feature description and split it into its core phenotype (the main disease, sign, or symptom) and any associated modifiers (such as clinical descriptors, severity, onset, localization, or temporal terms). Output raw JSON conforming strictly to the schema.";
    my $user_prompt     = "Analyze and split this clinical feature: '$term'";

    my $split_schema = {
        type => 'object',
        properties => {
            phenotype => { type => 'string', description => 'The core clinical phenotype or symptom term' },
            modifiers => {
                type => 'array',
                items => { type => 'string' },
                description => 'Any clinical modifiers, severity descriptors, temporal terms, or localization terms'
            }
        },
        required => ['phenotype', 'modifiers'],
        additionalProperties => \0
    };

    return $self->extract_structured_data_async($term, $split_schema, $sys_instruction, $user_prompt, $client_model)->then(sub {
        my $result = shift;
        if (ref $result eq 'HASH' && defined $result->{phenotype}) {
            return $result;
        }
        return { phenotype => $term, modifiers => [] };
    })->catch(sub {
        return { phenotype => $term, modifiers => [] };
    });
};

# Helper to recursively parse and split terms inside extracted group structures
helper split_hierarchical_group_async => sub {
    my ($self, $group, $client_model) = @_;
    return Mojo::Promise->resolve(undef) unless ref $group eq 'HASH';

    my $characteristics = $group->{characteristics} // [];
    my @promises;

    for (my $i = 0; $i < @$characteristics; $i++) {
        my $char = $characteristics->[$i];

        if (my $sym = $char->{symptom}) {
            my $labels = $sym->{labels} // ($sym->{label} ? [$sym->{label}] : []);
            my $exclude = $sym->{exclude};
            my $index = $i;

            my @split_promises;
            foreach my $lbl (@$labels) {
                push @split_promises, $self->split_symptom_components_async($lbl, $client_model);
            }

            my $p = Mojo::Promise->all(@split_promises)->then(sub {
                my @splits = @_;
                my @phenotypes;
                my @modifiers;
                foreach my $s_res (@splits) {
                    my $res = $s_res->[0];
                    if ($res && ref $res eq 'HASH') {
                        push @phenotypes, $res->{phenotype} if $res->{phenotype};
                        push @modifiers, @{$res->{modifiers} // []};
                    }
                }

                if (@modifiers) {
                    my @sub_chars;
                    foreach my $p_term (@phenotypes) {
                        push @sub_chars, {
                            symptom => {
                                labels => [$p_term],
                                exclude => \0,
                                combinationMethod => "all-of",
                                is_modifier => 0
                            }
                        };
                    }
                    foreach my $m_term (@modifiers) {
                        push @sub_chars, {
                            symptom => {
                                labels => [$m_term],
                                exclude => \0,
                                combinationMethod => "all-of",
                                is_modifier => 1
                            }
                        };
                    }

                    $characteristics->[$index] = {
                        subgroup => {
                            combinationMethod => "all-of",
                            composite_flag => 1, # Marks the subgroup as composite
                            characteristics => \@sub_chars
                        }
                    };
                } else {
                    $sym->{is_modifier} = 0;
                }
            });
            push @promises, $p;
        }
        elsif (my $sub = $char->{subgroup}) {
            my $p = $self->split_hierarchical_group_async($sub, $client_model);
            push @promises, $p;
        }
    }

    if (@promises) {
        return Mojo::Promise->all(@promises)->then(sub { return $group; });
    } else {
        return Mojo::Promise->resolve($group);
    }
};

# =========================================================
# RECURSIVE ASYNCHRONOUS HPO MAPPER HELPER (Order Preserving)
# =========================================================
helper map_hierarchical_group_async => sub {
    my ($self, $group) = @_;
    return Mojo::Promise->resolve(undef) unless ref $group eq 'HASH';

    my $combination_method = $group->{combinationMethod} // 'all-of';
    my $characteristics    = $group->{characteristics}    // [];

    my @promises;
    my @mapped_characteristics; # Pre-allocate array to preserve original indices

    for (my $i = 0; $i < @$characteristics; $i++) {
        my $char = $characteristics->[$i];

        if (my $sym = $char->{symptom}) {
            my $labels = $sym->{labels} // ($sym->{label} ? [$sym->{label}] : []);
            my $raw_exclude = $sym->{exclude};

            # Safe dereference of Mojo::JSON boolean references (\1 or \0)
            my $exclude = (ref $raw_exclude ? $$raw_exclude : $raw_exclude) ? 1 : 0;
            my $combination_method = $sym->{combinationMethod} // ($exclude ? 'neither-of' : 'all-of');
            my $is_modifier = $sym->{is_modifier} // 0; # Routed to proper modifier or core phenotype catalogs [25]

            # Strategic debug statement
            $self->app->log->debug(sprintf(
            "[DEBUG HPO Backend] Mapping element %d: labels=%s | is_modifier=%d | raw_exclude=%s | resolved_exclude=%d",
            $i + 1,
            join(', ', @$labels),
            $is_modifier,
            (defined $raw_exclude ? (ref $raw_exclude ? "ref(" . $$raw_exclude . ")" : $raw_exclude) : 'undef'),
            $exclude
            ));

            # Capture the current index in a lexical scope
            my $index = $i;
            my @label_promises;
            my @codings;

            for (my $j = 0; $j < @$labels; $j++) {
                my $lbl = $labels->[$j];
                my $lbl_idx = $j;

                my $p_lbl = $self->map_to_hpo_async($lbl, $is_modifier)->then(sub {
                    my $mapped_hpo = shift;
                    $codings[$lbl_idx] = {
                        system  => "http://human-phenotype-ontology.org",
                        code    => $mapped_hpo->{id},
                        display => $mapped_hpo->{label} // $lbl
                    };
                });
                push @label_promises, $p_lbl;
            }

            my $p;
            if (@label_promises) {
                $p = Mojo::Promise->all(@label_promises)->then(sub {
                    my @clean_codings = grep { defined } @codings;
                    $mapped_characteristics[$index] = {
                        exclude => $exclude ? \1 : \0,
                        combinationMethod => $combination_method,
                        valueCodeableConcept => {
                            coding => \@clean_codings
                        }
                    };
                });
            } else {
                $p = Mojo::Promise->resolve()->then(sub {
                    $mapped_characteristics[$index] = {
                        exclude => $exclude ? \1 : \0,
                        combinationMethod => $combination_method,
                        valueCodeableConcept => {
                            coding => []
                        }
                    };
                });
            }
            push @promises, $p;
        }
        elsif (my $sub = $char->{subgroup}) {
            my $index = $i;
            my $composite_flag = $sub->{composite_flag} // 0;

            my $p = $self->map_hierarchical_group_async($sub)->then(sub {
                my $mapped_subgroup = shift;
                if ($mapped_subgroup && $composite_flag) {
                    $mapped_subgroup->{id} = "composite-" . int(rand(1000000));
                    $mapped_subgroup->{membership} = "conceptual";
                    $mapped_subgroup->{type} = "person";
                }
                $mapped_characteristics[$index] = $mapped_subgroup if $mapped_subgroup;
            });
            push @promises, $p;
        }
    }

    if (@promises) {
        return Mojo::Promise->all(@promises)->then(sub {
            my @clean = grep { defined } @mapped_characteristics;
            return {
                resourceType      => "Group",
                combinationMethod => $combination_method,
                characteristic    => \@clean
            };
        });
    } else {
        return Mojo::Promise->resolve({
            resourceType      => "Group",
            combinationMethod => $combination_method,
            characteristic    => []
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
    # DEBUG-MOCK INTERVENTION (Multi-Token Modifiers Aligned)
    # =========================================================
    if (defined $selected_model && $selected_model eq 'mock-extractor') {
        $c->app->log->debug("[Backend] Model 'mock-extractor' detected. Bypassing LLM execution and returning mock structured JSON...");

        my $mock_data = {
            resourceType => "Group",
            combinationMethod => "all-of",
            characteristic => [
            {
                # Keratoconjunctivitis Sicca (Dry Eye Disease) - Composite Subgroup
                resourceType => "Group",
                id => "composite-mock-1",
                combinationMethod => "all-of",
                membership => "conceptual",
                type => "person",
                exclude => \0,
                characteristic => [
                {
                    exclude => \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => "HP:0001097",
                            display => "Keratoconjunctivitis Sicca"
                        }]
                    }
                },
                {
                    exclude => \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => "HP:0000118",
                            display => "Dry Eye Disease"
                        }]
                    }
                }
                ]
            },
            {
                # Corneal epithelial erosion or punctate keratitis - alternative options
                resourceType => "Group",
                combinationMethod => "any-of",
                exclude => \0,
                characteristic => [
                {
                    exclude => \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => "HP:0200147",
                            display => "corneal epithelial erosion"
                        }]
                    }
                },
                {
                    exclude => \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => "HP:0007718",
                            display => "punctate keratitis"
                        }]
                    }
                }
                ]
            },
            {
                # Severe ocular discomfort, foreign body sensation, or persistent ocular burning
                resourceType => "Group",
                combinationMethod => "any-of",
                exclude => \0,
                characteristic => [
                {
                    # Severe ocular discomfort - Composite Subgroup
                    resourceType => "Group",
                    id => "composite-mock-2",
                    combinationMethod => "all-of",
                    membership => "conceptual",
                    type => "person",
                    exclude => \0,
                    characteristic => [
                    {
                        exclude => \0,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0034333",
                                display => "ocular discomfort"
                            }]
                        }
                    },
                    {
                        exclude => \0,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0012828",
                                display => "severe"
                            }]
                        }
                    }
                    ]
                },
                {
                    exclude => \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => "HP:0034335",
                            display => "foreign body sensation"
                        }]
                    }
                },
                {
                    # Persistent ocular burning - Composite Subgroup
                    resourceType => "Group",
                    id => "composite-mock-3",
                    combinationMethod => "all-of",
                    membership => "conceptual",
                    type => "person",
                    exclude => \0,
                    characteristic => [
                    {
                        exclude => \0,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0034336",
                                display => "ocular burning"
                            }]
                        }
                    },
                    {
                        exclude => \0,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0031914",
                                display => "persistent"
                            }]
                        }
                    }
                    ]
                }
                ]
            },
            {
                # Decreased tear production - Composite Subgroup
                resourceType => "Group",
                id => "composite-mock-4",
                combinationMethod => "all-of",
                membership => "conceptual",
                type => "person",
                exclude => \0,
                characteristic => [
                {
                    exclude => \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => "HP:0000565",
                            display => "decreased tear production"
                        }]
                    }
                },
                {
                    exclude => \0,
                    valueCodeableConcept => {
                        coding => [{
                            system  => "http://human-phenotype-ontology.org",
                            code    => "HP:0012824",
                            display => "Schirmer's I"
                        }]
                    }
                }
                ]
            },
            {
                # Exclusion Criteria Group
                resourceType => "Group",
                combinationMethod => "all-of",
                exclude => \1,
                characteristic => [
                {
                    # Active ocular infection - Composite Subgroup
                    resourceType => "Group",
                    id => "composite-mock-5",
                    combinationMethod => "all-of",
                    membership => "conceptual",
                    type => "person",
                    exclude => \1,
                    characteristic => [
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0000598",
                                display => "ocular infection"
                            }]
                        }
                    },
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0003674",
                                display => "active"
                            }]
                        }
                    }
                    ]
                },
                {
                    # History of refractive corneal surgery - Composite Subgroup
                    resourceType => "Group",
                    id => "composite-mock-6",
                    combinationMethod => "all-of",
                    membership => "conceptual",
                    type => "person",
                    exclude => \1,
                    characteristic => [
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0032943",
                                display => "refractive corneal surgery"
                            }]
                        }
                    },
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0003577",
                                display => "history of"
                            }]
                        }
                    }
                    ]
                },
                {
                    # Secondary Sjögren's syndrome - Composite Subgroup
                    resourceType => "Group",
                    id => "composite-mock-7",
                    combinationMethod => "all-of",
                    membership => "conceptual",
                    type => "person",
                    exclude => \1,
                    characteristic => [
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0001497",
                                display => "Sjögren's syndrome"
                            }]
                        }
                    },
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0012823",
                                display => "secondary"
                            }]
                        }
                    }
                    ]
                },
                {
                    # Active ocular allergy - Composite Subgroup
                    resourceType => "Group",
                    id => "composite-mock-8",
                    combinationMethod => "all-of",
                    membership => "conceptual",
                    type => "person",
                    exclude => \1,
                    characteristic => [
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0001111",
                                display => "ocular allergy"
                            }]
                        }
                    },
                    {
                        exclude => \1,
                        valueCodeableConcept => {
                            coding => [{
                                system  => "http://human-phenotype-ontology.org",
                                code    => "HP:0003674",
                                display => "active"
                            }]
                        }
                    }
                    ]
                }
                ]
            }
            ]
        };

        return $c->render(json => $mock_data);
    }

    # =========================================================
    # REAL PIPELINE: EXTRACTION -> COGNITIVE SPLIT -> HPO MAP
    # =========================================================
    my $sys_instruction = "You are an expert medical entity extraction assistant. "
    . "Your task is to analyze the clinical trial synopsis and extract phenotypic features into a logical nested group structure.\n\n"
    . "LOGICAL GROUPING RULES:\n"
    . "1. MULTIPLE CODES PER SYMPTOM: For complex symptoms, list them inside the 'labels' array of the symptom.\n"
    . "2. INCLUSION VS EXCLUSION FLAGS: Set 'exclude': false and 'combinationMethod': 'all-of' or 'any-of' for symptoms listed under Inclusion Criteria. Set 'exclude': true and 'combinationMethod': 'neither-of' for symptoms listed under Exclusion Criteria.\n"
    . "3. EXCLUSION GROUPING: Group all exclusion criteria together in their own dedicated subgroup.\n"
    . "4. EXCLUSION OPERATOR (CRITICAL): Subgroups containing exclusion criteria elements ('exclude': true) MUST use 'combinationMethod': 'all-of'. "
    . "Mathematically, to reject a patient who has any of the excluded features, they must satisfy: (NOT Feature A) AND (NOT Feature B) AND (NOT Feature C). "
    . "Therefore, combining exclusion elements requires an 'all-of' combination method. Never use 'any-of' for an exclusion subgroup.\n"
    . "5. INCLUSION OPERATORS: Use 'all-of' (AND) to group mandatory inclusion criteria, and 'any-of' (OR) to group optional alternative symptoms.\n\n"
    . "You must output raw JSON ONLY conforming strictly to the requested schema. Do not write introductory text, explanations, or markdown formatting outside the JSON payload.";

    my $user_prompt = "Analyze the study protocol text, identify the inclusion/exclusion requirements, group them logically into subgroups, and extract nested criteria accordingly.";

    $c->extract_structured_data_async($text_content, $hierarchical_group_schema, $sys_instruction, $user_prompt, $selected_model)->then(sub {
        my $extracted_data = shift;

        # Step 1.5: Split core phenotypes and modifier entities recursively
        return $c->split_hierarchical_group_async($extracted_data, $selected_model)->then(sub {
            my $split_data = shift;

            # Step 2: Enforce exclusions logic
            enforce_exclusion_subgroup_logic($split_data);

            # Step 3: Run the aligned HPO mapping pipeline
            return $c->map_hierarchical_group_async($split_data)->then(sub {
                my $mapped_group = shift;
                if ($c->tx && !$c->tx->is_finished) {
                    $c->render(json => $mapped_group);
                }
            });
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
