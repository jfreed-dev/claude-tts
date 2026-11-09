#!/usr/bin/env bats
# Checks that the provider list and defaults in hooks/scripts/providers.sh
# agree with the README, commands/tts-setup.md and both manifests.
# Adding or removing a provider means updating every file this test reads.

REMOVED_PROVIDERS="azure"
GENERIC_KEYWORDS="tts text-to-speech voice audio speech"

setup() {
  cd "${BATS_TEST_DIRNAME}/.." || return 1
  PROVIDERS_SH="plugins/claude-tts/hooks/scripts/providers.sh"
  SETUP_MD="plugins/claude-tts/commands/tts-setup.md"
  PLUGIN_JSON="plugins/claude-tts/.claude-plugin/plugin.json"
  MARKETPLACE_JSON=".claude-plugin/marketplace.json"
  PROVIDERS=$(bash -c 'source "$0"; printf %s "$TTS_PROVIDERS"' "$PROVIDERS_SH")
  # Without this, a broken PROVIDERS_SH lets the per-provider loops pass with nothing checked.
  [ -n "$PROVIDERS" ] || { echo "no TTS_PROVIDERS from $PROVIDERS_SH"; return 1; }
}

# reg FUNCTION ARGS...: run a providers.sh function in a fresh bash.
reg() {
  bash -c 'source "$0"; "$@"' "$PROVIDERS_SH" "$@"
}

flunk() {
  printf '%s\n' "$*"
  return 1
}

# section FILE HEADING: print the lines after HEADING up to the next heading.
section() {
  awk -v h="$2" '$0==h{f=1;next} f&&/^#/{exit} f' "$1"
}

# words LIST: one word per line, sorted.
words() {
  printf '%s\n' "$1" | tr -s '[:space:]' '\n' | sed '/^$/d' | sort
}

# same_set A B: A and B hold the same words, and neither repeats one.
same_set() {
  local dups
  dups=$( { words "$1" | uniq -d; words "$2" | uniq -d; } )
  [ -z "$dups" ] || flunk "repeated: $dups"
  [ "$(words "$1")" = "$(words "$2")" ] || flunk "sets differ: [$(words "$1" | tr '\n' ' ')] vs [$(words "$2" | tr '\n' ' ')]"
}

# one_each NAMES: one name per provider (NAMES is newline separated), and
# each provider id appears as a word in exactly one lowercased name.
one_each() {
  local names count expected p n
  names=$(printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]')
  count=$(printf '%s\n' "$names" | grep -c . || true)
  expected=$(words "$PROVIDERS" | grep -c .)
  [ "$count" -eq "$expected" ] || flunk "expected $expected names, got $count: $(printf '%s\n' "$names" | tr '\n' ';')"
  for p in $PROVIDERS; do
    n=$(printf '%s\n' "$names" | grep -cw -- "$p" || true)
    [ "$n" -eq 1 ] || flunk "$p matches $n names"
  done
}

# keyword_provider KEYWORD: the provider id a manifest keyword stands for.
keyword_provider() {
  case "$1" in
    polly) echo amazon ;;
    xiaomi) echo mimo ;;
    hume) echo tada ;;
    fish-speech|fish-audio) echo fish ;;
    *) echo "$1" ;;
  esac
}

@test "registry is complete for every provider" {
  local p
  for p in $PROVIDERS; do
    [ -n "$(reg tts_provider_summary "$p")" ] || flunk "$p: no summary"
    [ -n "$(reg tts_provider_audio_ext "$p")" ] || flunk "$p: no audio extension"
    [ -n "$(reg tts_provider_config_notes "$p")" ] || flunk "$p: no config notes"
    if reg tts_provider_needs_key "$p"; then
      [ -n "$(reg tts_provider_key_url "$p")" ] || flunk "$p: needs a key but has no key URL"
    fi
    if [ "$p" != local ]; then
      reg declare -F "_tts_synth_$p" > /dev/null || flunk "$p: no _tts_synth_$p"
    fi
  done
  for p in $REMOVED_PROVIDERS; do
    if reg tts_provider_is_valid "$p"; then
      flunk "$p was removed but tts_provider_is_valid accepts it"
    fi
  done
}

@test "tts-setup.md lists every provider with the registry summary" {
  local want got expected p
  want="description: Set up TTS with a provider ($(printf '%s' "$PROVIDERS" | sed 's/ /, /g'))"
  [ "$(sed -n 2p "$SETUP_MD")" = "$want" ] || flunk "line 2 should be: $want"
  # The backticks below are literal Markdown, not command substitution.
  # shellcheck disable=SC2016
  got=$(grep -E '^- `[a-z]+`' "$SETUP_MD" || true)
  expected=$(for p in $PROVIDERS; do
    # shellcheck disable=SC2016
    printf -- '- `%s`: %s\n' "$p" "$(reg tts_provider_summary "$p")"
  done)
  [ "$(printf '%s\n' "$got" | grep -c . || true)" -eq "$(words "$PROVIDERS" | grep -c .)" ] ||
    flunk "provider bullet count differs from the registry"
  [ "$got" = "$expected" ] || flunk "provider bullets differ. Expected:" "$expected" "Got:" "$got"
}

@test "README provider details match the registry defaults" {
  local rows id voice model dv dm cfg cp cv cm
  rows=$(section README.md "### Provider details" | grep -E '^\| [a-z]+ \|' |
    awk -F'|' '{ for (i = 2; i <= 4; i++) gsub(/^ +| +$/, "", $i); print $2 "\t" $3 "\t" $4 }')
  same_set "$(printf '%s\n' "$rows" | cut -f1)" "$PROVIDERS"
  while IFS=$'\t' read -r id voice model; do
    dv=$(reg tts_provider_default voice "$id")
    dm=$(reg tts_provider_default model "$id")
    if [[ "$dv" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      [[ "$voice" == *"\`$dv\`"* ]] || flunk "$id: voice cell '$voice' lacks \`$dv\`"
    elif [ -z "$dv" ]; then
      [[ "$voice" != *"\`"* ]] || flunk "$id: no default voice, but the voice cell '$voice' names one"
    fi
    if [ -z "$dm" ]; then
      [ "$model" = "n/a" ] || flunk "$id: no default model, but the model cell is '$model'"
    else
      [[ "$model" == *"\`$dm\`"* ]] || flunk "$id: model cell '$model' lacks \`$dm\`"
    fi
  done <<< "$rows"

  cfg=$(section README.md "## Configuration")
  cp=$(printf '%s\n' "$cfg" | sed -n 's/^provider: "\(.*\)"$/\1/p')
  cv=$(printf '%s\n' "$cfg" | sed -n 's/^voice_id: "\(.*\)"$/\1/p')
  cm=$(printf '%s\n' "$cfg" | sed -n 's/^model_id: "\(.*\)"$/\1/p')
  [ -n "$cp" ] || flunk "no provider in the Configuration example"
  [ "$cv" = "$(reg tts_provider_default voice "$cp")" ] || flunk "Configuration example voice_id '$cv' is not the $cp default"
  [ "$cm" = "$(reg tts_provider_default model "$cp")" ] || flunk "Configuration example model_id '$cm' is not the $cp default"
}

@test "README examples cover every provider once" {
  local ids
  ids=$(section README.md "### Examples" | sed -n 's|^/claude-tts:tts-setup \([a-z][a-z]*\).*|\1|p')
  same_set "$ids" "$PROVIDERS"
}

@test "README supported providers table has one row per provider" {
  local names
  names=$(section README.md "## Supported Providers" | sed -n 's/^| \*\*\([^*]*\)\*\* |.*/\1/p')
  one_each "$names"
}

@test "manifests describe and tag every provider" {
  if ! command -v jq > /dev/null; then
    skip "jq is not installed"
  fi
  local pd md list k p mapped covered=""
  pd=$(jq -r '.description' "$PLUGIN_JSON")
  md=$(jq -r '.plugins[] | select(.name == "claude-tts") | .description' "$MARKETPLACE_JSON")
  [ "$pd" = "$md" ] || flunk "plugin.json and marketplace.json descriptions differ"
  list=$(printf '%s\n' "$pd" | sed -n 's/.*(\(.*\)).*/\1/p' | tr ',' '\n' | sed 's/^ *//')
  one_each "$list"

  for k in $(jq -r '.keywords[]' "$PLUGIN_JSON"); do
    case " $GENERIC_KEYWORDS " in
      *" $k "*) continue ;;
    esac
    mapped=$(keyword_provider "$k")
    reg tts_provider_is_valid "$mapped" || flunk "keyword '$k' is not generic, an alias or a provider id"
    covered="$covered $mapped"
  done
  for p in $PROVIDERS; do
    if [ "$p" = local ]; then
      continue
    fi
    case " $covered " in
      *" $p "*) ;;
      *) flunk "no keyword covers $p" ;;
    esac
  done
}

@test "removed providers are absent from the docs and manifests" {
  local r hits f
  for r in $REMOVED_PROVIDERS; do
    hits=$(awk -v r="$r" '/^#/{skip=index(tolower($0),r)>0} !skip&&index(tolower($0),r)' README.md)
    [ -z "$hits" ] || flunk "README mentions $r outside its removal note: $hits"
    for f in "$SETUP_MD" "$PLUGIN_JSON" "$MARKETPLACE_JSON"; do
      if grep -qi -- "$r" "$f"; then
        flunk "$f mentions removed provider $r"
      fi
    done
  done
}
