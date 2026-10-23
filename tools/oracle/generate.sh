#!/usr/bin/env bash
# Regenerates Tests/EcuCoreTests/Resources/oracle/*.jsonl by running the ORIGINAL
# Java classes of cedricp/ecutweaker (Ecu.java, Layout.java, IsoTP*.java) on random
# inputs. The Swift tests (OracleTests) must reproduce these outputs exactly.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
WORK="$(mktemp -d)"
git clone --depth 1 -q https://github.com/cedricp/ecutweaker.git "$WORK/ecutweaker"
git clone --depth 1 -q https://github.com/stleary/JSON-java.git "$WORK/json"
mkdir -p "$WORK/src/org/quark/dr/ecu" "$WORK/classes"
cp "$WORK"/ecutweaker/ecu/src/main/java/org/quark/dr/ecu/{Ecu,Layout,IsoTPEncode,IsoTPDecode}.java "$WORK/src/org/quark/dr/ecu/"
cp "$HERE/Oracle.java" "$WORK/src/org/quark/dr/ecu/"
cp -r "$WORK/json/src/main/java/org/json" "$WORK/src/org/"
cp -r "$HERE/stubs/android" "$WORK/src/"
javac -nowarn -encoding UTF-8 -d "$WORK/classes" $(find "$WORK/src" -name "*.java")
RES="$ROOT/Tests/EcuCoreTests/Resources"
for f in test.json UCH_LE.json acu.json DDCR_-_BEB2_a_BEB4_-_v5.0.json; do
  java -cp "$WORK/classes" org.quark.dr.ecu.Oracle "$RES/$f" "$RES/oracle/$f.jsonl" 42 12
done
java -cp "$WORK/classes" org.quark.dr.ecu.Oracle format "$RES/oracle/formats.jsonl" 7 4000
rm -rf "$WORK"
echo "oracle data regenerated"
