#!/usr/bin/env bash
# shellcheck shell=bash
# providers.sh: the single definition of every TTS provider, shared by
# tts-worker.sh and tts-setup.sh.
# Requires platform.sh to be sourced first (uses file_size).
# Top level holds only constants and function definitions, so it is safe to
# source under set -euo pipefail.

TTS_PROVIDERS="elevenlabs openai google amazon edge kitten mimo tada fish gemini local"

# Knobs callers may reassign after sourcing.
TTS_CURL_MAX_TIME=30
TTS_SYNTH_VERBOSE=0

# Set by tts_synth: the HTTP status for API providers, or 200/000 from the
# exit status of CLI and Python providers.
TTS_HTTP_CODE=""

TTS_TADA_CACHE="$HOME/.claude/tada-prompt-cache.pt"

# --- Provider metadata ---

tts_provider_is_valid() {
  local p
  for p in $TTS_PROVIDERS; do
    if [[ "$1" == "$p" ]]; then
      return 0
    fi
  done
  return 1
}

# Returns 0 if the provider needs an API key. Use only in conditions.
tts_provider_needs_key() {
  case "$1" in
    local|amazon|edge|kitten|tada) return 1 ;;
    *) return 0 ;;
  esac
}

# tts_provider_default FIELD PROVIDER; FIELD is voice or model.
# Prints the default (empty if none) and always returns 0.
tts_provider_default() {
  case "$1:$2" in
    voice:elevenlabs) printf '%s' "21m00Tcm4TlvDq8ikWAM" ;;
    model:elevenlabs) printf '%s' "eleven_flash_v2_5" ;;
    voice:openai)     printf '%s' "alloy" ;;
    model:openai)     printf '%s' "tts-1" ;;
    voice:google)     printf '%s' "en-US-Neural2-F" ;;
    voice:amazon)     printf '%s' "Joanna" ;;
    model:amazon)     printf '%s' "neural" ;;
    voice:edge)       printf '%s' "en-US-AriaNeural" ;;
    voice:kitten)     printf '%s' "expr-voice-2-f" ;;
    voice:mimo)       printf '%s' "mimo_default" ;;
    model:mimo)       printf '%s' "mimo-v2-tts" ;;
    voice:tada)       printf '%s' "$HOME/.claude/tada-reference.wav" ;;
    model:tada)       printf '%s' "tada-1b" ;;
    model:fish)       printf '%s' "s2-pro" ;;
    voice:gemini)     printf '%s' "Kore" ;;
    model:gemini)     printf '%s' "gemini-3.1-flash-tts-preview" ;;
  esac
  return 0
}

# Prints the audio file extension for a provider (empty if unknown).
tts_provider_audio_ext() {
  case "$1" in
    elevenlabs|openai|google|amazon|edge|fish) printf '%s' "mp3" ;;
    kitten|mimo|tada|gemini|local) printf '%s' "wav" ;;
  esac
  return 0
}

tts_validate_audio() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  local size
  size=$(file_size "$file")
  if [[ "$size" -lt 1024 ]]; then
    rm -f "$file"
    return 1
  fi
  return 0
}

# --- Synthesis entry point ---

# tts_synth PROVIDER OUTFILE TEXT VOICE MODEL API_KEY
# Returns 0 only when OUTFILE exists and is at least 1024 bytes; on failure
# OUTFILE is removed. Sets TTS_HTTP_CODE.
tts_synth() {
  TTS_HTTP_CODE="000"
  local provider="$1"
  shift
  case "$provider" in
    elevenlabs|openai|google|amazon|edge|kitten|mimo|tada|fish|gemini)
      "_tts_synth_${provider}" "$@"
      ;;
    *)
      return 1
      ;;
  esac
}

# _tts_http_post OUTFILE URL BODY HEADER... (callers pass at least two headers)
# Prints the HTTP status, or 000 appended if curl itself fails.
_tts_http_post() {
  local out="$1" url="$2" body="$3"
  shift 3
  local -a hargs=()
  local h
  for h in "$@"; do
    hargs+=(-H "$h")
  done
  curl -s -w "%{http_code}" -o "$out" --max-time "$TTS_CURL_MAX_TIME" -X POST "$url" "${hargs[@]}" -d "$body" 2>/dev/null || echo "000"
}

# --- Providers: each takes OUTFILE TEXT VOICE MODEL API_KEY ---

_tts_synth_elevenlabs() {
  local out="$1" text="$2" voice="$3" model="$4" key="$5"
  local body
  body=$(jq -n --arg text "$text" --arg model "$model" '{
    text: $text,
    model_id: $model
  }')

  TTS_HTTP_CODE=$(_tts_http_post "$out" "https://api.elevenlabs.io/v1/text-to-speech/${voice}" "$body" \
    "xi-api-key: ${key}" \
    "Content-Type: application/json")

  if [[ "$TTS_HTTP_CODE" != "200" ]]; then
    rm -f "$out"
    return 1
  fi
  tts_validate_audio "$out"
}

_tts_synth_openai() {
  local out="$1" text="$2" voice="$3" model="$4" key="$5"
  local body
  body=$(jq -n --arg text "$text" --arg model "$model" --arg voice "$voice" '{
    model: $model,
    input: $text,
    voice: $voice,
    response_format: "mp3"
  }')

  TTS_HTTP_CODE=$(_tts_http_post "$out" "https://api.openai.com/v1/audio/speech" "$body" \
    "Authorization: Bearer ${key}" \
    "Content-Type: application/json")

  if [[ "$TTS_HTTP_CODE" != "200" ]]; then
    rm -f "$out"
    return 1
  fi
  tts_validate_audio "$out"
}

_tts_synth_google() {
  local out="$1" text="$2" voice="$3" key="$5"
  local body
  body=$(jq -n --arg text "$text" --arg voice "$voice" '{
    input: { text: $text },
    voice: {
      languageCode: "en-US",
      name: $voice
    },
    audioConfig: { audioEncoding: "MP3" }
  }')

  local tmp_response
  tmp_response=$(mktemp "${TMPDIR:-/tmp}/claude_tts_gcloud.XXXXXX")

  TTS_HTTP_CODE=$(_tts_http_post "$tmp_response" "https://texttospeech.googleapis.com/v1/text:synthesize" "$body" \
    "X-Goog-Api-Key: ${key}" \
    "Content-Type: application/json")

  if [[ "$TTS_HTTP_CODE" != "200" ]]; then
    rm -f "$tmp_response" "$out"
    return 1
  fi

  # Google returns base64-encoded audio in JSON
  jq -r '.audioContent' "$tmp_response" 2>/dev/null | base64 -d > "$out" 2>/dev/null
  rm -f "$tmp_response"
  tts_validate_audio "$out"
}

_tts_synth_amazon() {
  local out="$1" text="$2" voice="$3" model="$4"

  if ! command -v aws &>/dev/null; then
    return 1
  fi

  if aws polly synthesize-speech \
    --output-format mp3 \
    --voice-id "$voice" \
    --engine "$model" \
    --text "$text" \
    "$out" &>/dev/null; then
    TTS_HTTP_CODE="200"
  fi

  tts_validate_audio "$out"
}

_tts_synth_edge() {
  local out="$1" text="$2" voice="$3"

  if ! command -v edge-tts &>/dev/null; then
    return 1
  fi

  if edge-tts --voice "$voice" --text "$text" --write-media "$out" &>/dev/null; then
    TTS_HTTP_CODE="200"
  fi

  tts_validate_audio "$out"
}

_tts_synth_kitten() {
  local out="$1" text="$2" voice="$3"

  if ! python3 -c "import kittentts" &>/dev/null; then
    return 1
  fi

  if _tts_kitten_python "$out" "$text" "$voice"; then
    TTS_HTTP_CODE="200"
  fi

  tts_validate_audio "$out"
}

# _tts_kitten_python OUTFILE TEXT VOICE
_tts_kitten_python() {
  KITTEN_TEXT="$2" KITTEN_VOICE="$3" KITTEN_OUTPUT="$1" \
    python3 -c "
import os, soundfile as sf
from kittentts import KittenTTS
model = KittenTTS()
audio = model.generate(text=os.environ['KITTEN_TEXT'], voice=os.environ['KITTEN_VOICE'], speed=1.0)
sf.write(os.environ['KITTEN_OUTPUT'], audio, 24000)
" &>/dev/null
}

_tts_synth_mimo() {
  local out="$1" text="$2" voice="$3" model="$4" key="$5"
  local body
  body=$(jq -n --arg text "$text" --arg model "$model" --arg voice "$voice" '{
    model: $model,
    messages: [
      { role: "assistant", content: $text }
    ],
    audio: {
      format: "wav",
      voice: $voice
    }
  }')

  local tmp_response
  tmp_response=$(mktemp "${TMPDIR:-/tmp}/claude_tts_mimo.XXXXXX")

  TTS_HTTP_CODE=$(_tts_http_post "$tmp_response" "https://api.xiaomimimo.com/v1/chat/completions" "$body" \
    "api-key: ${key}" \
    "Content-Type: application/json")

  if [[ "$TTS_HTTP_CODE" != "200" ]]; then
    rm -f "$tmp_response" "$out"
    return 1
  fi

  # MiMo returns base64-encoded audio in message.audio.data
  jq -r '.choices[0].message.audio.data' "$tmp_response" 2>/dev/null | base64 -d > "$out" 2>/dev/null
  rm -f "$tmp_response"
  tts_validate_audio "$out"
}

_tts_synth_tada() {
  local out="$1" text="$2" voice="$3" model="$4"

  if ! python3 -c "import tada" &>/dev/null; then
    return 1
  fi

  # Setup sets TTS_SYNTH_VERBOSE=1 so model download progress and errors show.
  local rc=0
  if [[ "$TTS_SYNTH_VERBOSE" == 1 ]]; then
    _tts_tada_python "$out" "$text" "$model" "$voice" "$TTS_TADA_CACHE" || rc=$?
  else
    _tts_tada_python "$out" "$text" "$model" "$voice" "$TTS_TADA_CACHE" &>/dev/null || rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then
    TTS_HTTP_CODE="200"
  fi

  tts_validate_audio "$out"
}

# _tts_tada_python OUTFILE TEXT MODEL REF_AUDIO CACHE
_tts_tada_python() {
  TADA_TEXT="$2" TADA_OUTPUT="$1" TADA_MODEL="$3" \
    TADA_REF_AUDIO="$4" TADA_CACHE="$5" \
    python3 -c "
import os, sys, torch, torchaudio
from tada.modules.encoder import EncoderOutput
from tada.modules.tada import TadaForCausalLM

text = os.environ['TADA_TEXT']
output_path = os.environ['TADA_OUTPUT']
model_name = 'HumeAI/' + os.environ.get('TADA_MODEL', 'tada-1b')
ref_audio_path = os.environ.get('TADA_REF_AUDIO', '')
cache_path = os.environ.get('TADA_CACHE', '')

if torch.cuda.is_available():
    device, dtype = 'cuda', torch.bfloat16
elif hasattr(torch.backends, 'mps') and torch.backends.mps.is_available():
    device, dtype = 'mps', torch.float32
else:
    device, dtype = 'cpu', torch.float32

if cache_path and os.path.exists(cache_path):
    prompt = EncoderOutput.load(cache_path, device=device)
else:
    from tada.modules.encoder import Encoder
    if not ref_audio_path or not os.path.exists(ref_audio_path):
        sys.exit(1)
    encoder = Encoder.from_pretrained('HumeAI/tada-codec', subfolder='encoder').to(device)
    audio, sr = torchaudio.load(ref_audio_path)
    audio = audio.to(device)
    prompt = encoder(audio, sample_rate=sr)
    if cache_path:
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        prompt.save(cache_path)
    del encoder

model = TadaForCausalLM.from_pretrained(model_name, torch_dtype=dtype).to(device)
if hasattr(model, 'decoder'):
    model.decoder.to(device)
output = model.generate(prompt=prompt, text=text)
wav = output.audio[0].detach().cpu().float()
if wav.dim() == 1:
    wav = wav.unsqueeze(0)
torchaudio.save(output_path, wav, 24000)
"
}

_tts_synth_fish() {
  local out="$1" text="$2" voice="$3" model="$4" key="$5"
  local body
  if [[ -n "$voice" ]]; then
    body=$(jq -n --arg text "$text" --arg ref "$voice" '{
      text: $text,
      format: "mp3",
      reference_id: $ref
    }')
  else
    body=$(jq -n --arg text "$text" '{
      text: $text,
      format: "mp3"
    }')
  fi

  TTS_HTTP_CODE=$(_tts_http_post "$out" "https://api.fish.audio/v1/tts" "$body" \
    "Authorization: Bearer ${key}" \
    "Content-Type: application/json" \
    "model: ${model}")

  if [[ "$TTS_HTTP_CODE" != "200" ]]; then
    rm -f "$out"
    return 1
  fi
  tts_validate_audio "$out"
}

_tts_synth_gemini() {
  local out="$1" text="$2" voice="$3" model="$4" key="$5"
  local body
  body=$(jq -n --arg text "$text" --arg voice "$voice" '{
    contents: [{ parts: [{ text: $text }] }],
    generationConfig: {
      responseModalities: ["AUDIO"],
      speechConfig: {
        voiceConfig: {
          prebuiltVoiceConfig: { voiceName: $voice }
        }
      }
    }
  }')

  local tmp_response
  tmp_response=$(mktemp "${TMPDIR:-/tmp}/claude_tts_gemini.XXXXXX")

  TTS_HTTP_CODE=$(_tts_http_post "$tmp_response" "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" "$body" \
    "x-goog-api-key: ${key}" \
    "Content-Type: application/json")

  if [[ "$TTS_HTTP_CODE" != "200" ]]; then
    rm -f "$tmp_response" "$out"
    return 1
  fi

  # Gemini returns base64-encoded PCM (s16le, 24kHz, mono); wrap it in WAV
  local pcm_file
  pcm_file=$(mktemp "${TMPDIR:-/tmp}/claude_tts_pcm.XXXXXX")
  jq -r '.candidates[0].content.parts[0].inlineData.data' "$tmp_response" 2>/dev/null | base64 -d > "$pcm_file" 2>/dev/null
  rm -f "$tmp_response"

  local pcm_size
  pcm_size=$(file_size "$pcm_file")
  if [[ "$pcm_size" -lt 100 ]]; then
    rm -f "$pcm_file" "$out"
    return 1
  fi

  _tts_pcm_to_wav "$pcm_file" "$out"
  rm -f "$pcm_file"

  tts_validate_audio "$out"
}

# _tts_pcm_to_wav PCM_FILE WAV_FILE
_tts_pcm_to_wav() {
  python3 -c "
import struct, sys
pcm = open(sys.argv[1], 'rb').read()
with open(sys.argv[2], 'wb') as f:
    f.write(b'RIFF')
    f.write(struct.pack('<I', len(pcm) + 36))
    f.write(b'WAVEfmt ')
    f.write(struct.pack('<IHHIIHH', 16, 1, 1, 24000, 48000, 2, 16))
    f.write(b'data')
    f.write(struct.pack('<I', len(pcm)))
    f.write(pcm)
" "$1" "$2" 2>/dev/null
}
