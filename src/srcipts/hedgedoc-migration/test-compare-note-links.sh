#!/bin/sh
set -eu

# Mock only the curl transport; the comparison logic and real response files
# still run unchanged. No network, credentials or external dependencies.
DIR=$(mktemp -d)
cat > "$DIR/curl" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        -w|--max-time) shift 2 ;;
        --silent|--show-error) shift ;;
        *) url=$1; shift ;;
    esac
done
case "$url" in *old.example*) side=old ;; *) side=new ;; esac
case "$url" in
    */note) code=200; body='<title>Same note</title>'; loc= ;;
    */same/info)
        code=200; loc=
        if [ "$side" = old ]; then body='{"viewcount":1,"content":"same"}'
        else body='{"viewcount":2,"content":"same"}'; fi ;;
    */different/info)
        code=200; loc=
        if [ "$side" = old ]; then body='{"viewcount":1,"content":"first"}'
        else body='{"viewcount":2,"content":"second"}'; fi ;;
    */bad) code=500; loc=; body=error ;;
    */redirect)
        code=302; body=
        if [ "$side" = old ]; then loc=https://old.example/note
        else loc=https://new.example/note; fi ;;
    */unreachable) exit 7 ;;
    *) code=404; body=missing; loc= ;;
esac
printf '%s' "$body" > "$out"
printf '%s %s' "$code" "$loc"
SH
chmod +x "$DIR/curl"
PATH="$DIR:$PATH"
export PATH
printf '/note\n/same/info\n/redirect\n' > "$DIR/ok"
printf '/different/info\n/bad\n/unreachable\n' > "$DIR/bad"
export A_BASE=http://old.example B_BASE=http://new.example
export A_HOST=old.example B_HOST=new.example
SCRIPT=$(dirname "$0")/compare-note-links.sh
sh "$SCRIPT" "$DIR/ok" > "$DIR/ok.tsv"
grep -q '^OK[[:space:]]/same/info[[:space:]]' "$DIR/ok.tsv"
if sh "$SCRIPT" "$DIR/bad" > "$DIR/bad.tsv"; then
    echo 'Different note and 500 must not pass' >&2
    exit 1
fi
grep -q '^DIFF[[:space:]]/different/info[[:space:]]' "$DIR/bad.tsv"
grep -q '^ERROR[[:space:]]/bad[[:space:]]' "$DIR/bad.tsv"
grep -q '^ERROR[[:space:]]/unreachable[[:space:]]' "$DIR/bad.tsv"
echo 'compare-note-links: PASS'
