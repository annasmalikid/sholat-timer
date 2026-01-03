#!/bin/bash
set -euo pipefail

API_BASE="https://api.myquran.com/v2"
CITY_KEY="bekasi"

UNIT_DIR="$HOME/.config/systemd/user"
TIMER_FILE="$UNIT_DIR/reminder-lock.timer"

CACHE_DIR="$HOME/.cache"
CITY_ID_FILE="$CACHE_DIR/myquran_${CITY_KEY}_kota_id"
SCHEDULE_FILE="$CACHE_DIR/sholat_schedule.tsv"
CUTOFF_FILE="$CACHE_DIR/sholat_cutoff_isha"

mkdir -p "$UNIT_DIR" "$CACHE_DIR"

need() { command -v "$1" >/dev/null 2>&1; }
need curl
need jq
need date

log() { echo "[update-sholat] $*" >&2; }

curl_fast() { curl -fsSL --connect-timeout 5 --max-time 15 "$@"; }

# Ambil kota_id (cache)
if [[ -f "$CITY_ID_FILE" ]]; then
  KOTA_ID="$(cat "$CITY_ID_FILE")"
else
  log "Fetching kota list…"
  KOTA_JSON="$(curl_fast "$API_BASE/sholat/kota/semua")"
  KOTA_ID="$(echo "$KOTA_JSON" | jq -r '.data[] | select(.lokasi|test("bekasi";"i")) | .id' | head -n1)"
  if [[ -z "${KOTA_ID:-}" || "$KOTA_ID" == "null" ]]; then
    log "ERROR: tidak menemukan kota Bekasi."
    exit 1
  fi
  echo "$KOTA_ID" > "$CITY_ID_FILE"
fi

get_day_json() {
  curl_fast "$API_BASE/sholat/jadwal/$KOTA_ID/$1/$2/$3"
}

# Ambil waktu dengan fallback key (karena variasi penamaan di beberapa sumber)
get_time_any() {
  local json="$1"; shift
  local key val
  for key in "$@"; do
    val="$(echo "$json" | jq -r ".data.jadwal.${key} // empty" | sed 's/[^0-9:]//g' | cut -c1-5)"
    if [[ "$val" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
      echo "$val"
      return 0
    fi
  done
  echo ""
  return 1
}

NOW_EPOCH="$(date +%s)"
TODAY="$(date +%Y-%m-%d)"
Y="$(date +%Y)"; M="$(date +%m)"; D="$(date +%d)"

log "Fetching jadwal: $TODAY (kota_id=$KOTA_ID)…"
JSON_TODAY="$(get_day_json "$Y" "$M" "$D")"

FAJR="$(get_time_any "$JSON_TODAY" subuh)"
DHUHR="$(get_time_any "$JSON_TODAY" dzuhur zuhur)"
ASR="$(get_time_any "$JSON_TODAY" ashar asar)"
MAGHRIB="$(get_time_any "$JSON_TODAY" maghrib)"
ISHA="$(get_time_any "$JSON_TODAY" isya isha)"

# Validasi keras
for pair in "Subuh:$FAJR" "Dzuhur:$DHUHR" "Ashar:$ASR" "Maghrib:$MAGHRIB" "Isya:$ISHA"; do
  name="${pair%%:*}"
  t="${pair#*:}"
  if ! [[ "$t" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
    log "ERROR: waktu $name tidak valid/empty: '$t'"
    log "TIP: cek output JSON: echo '$JSON_TODAY' | jq '.data.jadwal'"
    exit 1
  fi
done

ISHA_EPOCH="$(date -d "$TODAY $ISHA" +%s)"

# Mode tidur: jika sudah lewat Isya → gunakan jadwal BESOK
if (( NOW_EPOCH >= ISHA_EPOCH )); then
  DAY="$(date -d tomorrow +%Y-%m-%d)"
  Y="$(date -d tomorrow +%Y)"; M="$(date -d tomorrow +%m)"; D="$(date -d tomorrow +%d)"
  log "After Isya → using tomorrow: $DAY"
  JSON_TODAY="$(get_day_json "$Y" "$M" "$D")"

  FAJR="$(get_time_any "$JSON_TODAY" subuh)"
  DHUHR="$(get_time_any "$JSON_TODAY" dzuhur zuhur)"
  ASR="$(get_time_any "$JSON_TODAY" ashar asar)"
  MAGHRIB="$(get_time_any "$JSON_TODAY" maghrib)"
  ISHA="$(get_time_any "$JSON_TODAY" isya isha)"

  for pair in "Subuh:$FAJR" "Dzuhur:$DHUHR" "Ashar:$ASR" "Maghrib:$MAGHRIB" "Isya:$ISHA"; do
    name="${pair%%:*}"
    t="${pair#*:}"
    if ! [[ "$t" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
      log "ERROR: waktu $name (besok) tidak valid/empty: '$t'"
      exit 1
    fi
  done
else
  DAY="$TODAY"
fi

# Cache jadwal lengkap
cat > "$SCHEDULE_FILE" <<EOF
$DAY	Subuh	$FAJR
$DAY	Dzuhur	$DHUHR
$DAY	Ashar	$ASR
$DAY	Maghrib	$MAGHRIB
$DAY	Isya	$ISHA
EOF

# Cutoff Isya
echo "$DAY $ISHA" > "$CUTOFF_FILE"

# Timer 5 waktu sholat saja, tanpa "kejar" event lama
cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Reminder Lock Timer (Auto: Sholat Bekasi)

[Timer]
OnCalendar=$DAY ${FAJR}:00
OnCalendar=$DAY ${DHUHR}:00
OnCalendar=$DAY ${ASR}:00
OnCalendar=$DAY ${MAGHRIB}:00
OnCalendar=$DAY ${ISHA}:00
Persistent=false

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now reminder-lock.timer >/dev/null 2>&1 || true
systemctl --user restart reminder-lock.timer >/dev/null 2>&1 || true

log "OK: day=$DAY kota_id=$KOTA_ID (Subuh $FAJR, Isya $ISHA)"
