#!/bin/sh
# Compare anonymous note URLs without following redirects. Set A_HOST/B_HOST
# to the public hostnames configured in each application's CMD_DOMAIN.
set -eu
A=${A_BASE:-http://codimd:3000}
B=${B_BASE:-http://hedgedoc:3000}
: "${A_HOST:?Set A_HOST}" "${B_HOST:?Set B_HOST}"
test "$#" -eq 1 && test -r "$1" || { echo 'Usage: compare-note-links.sh paths.txt' >&2; exit 2; }

work=$(mktemp -d)
bad=0
probe() {
    if result=$(curl --silent --show-error --max-time 30 -o "$3" -w '%{http_code} %{redirect_url}' "$1$2" 2>/dev/null); then
        printf '%s' "$result"
    else
        printf '000 '
    fi
}
location() {
    case "$1" in
        '') printf '' ;;
        "https://$2"| "https://$2/"*) printf '%s' "${1#https://$2}" ;;
        *) printf 'FOREIGN:%s' "$1" ;;
    esac
}
title() {
    tr -d '\n' < "$1" | sed -nE 's#.*<title>([^<]*)</title>.*#\1#p' | head -c 300
}
info() {
    # Views of /s/ increment only in the live CodiMD database.
    sed -E 's/"viewcount":[0-9]+//g' "$1"
}

printf 'verdict\tpath\ta_code\tb_code\ta_loc\tb_loc\tcheck\n'
while IFS= read -r path || [ -n "$path" ]; do
    path=$(printf '%s' "$path" | tr -d '\r')
    [ -z "$path" ] && continue
    case "$path" in
        /*) ;;
        *) echo "Not a relative URL path: $path" >&2; exit 2 ;;
    esac
    a=$(probe "$A" "$path" "$work/a")
    b=$(probe "$B" "$path" "$work/b")
    ac=${a%% *}; bc=${b%% *}
    al=${a#"$ac"}; bl=${b#"$bc"}
    al=$(location "${al# }" "$A_HOST")
    bl=$(location "${bl# }" "$B_HOST")
    check=-
    if [ "$ac" = 200 ] && [ "$bc" = 200 ]; then
        case "${path%%\?*}" in
            */download|*/revision|*/revision/*)
                if cmp -s "$work/a" "$work/b"; then check=body-same; else check=body-diff; fi ;;
            */info)
                if [ "$(info "$work/a")" = "$(info "$work/b")" ]; then check=body-same; else check=body-diff; fi ;;
            *)
                if [ "$(title "$work/a")" = "$(title "$work/b")" ]; then check=title-same; else check=title-diff; fi ;;
        esac
    fi
    verdict=OK
    [ "$ac" = 000 ] && verdict=ERROR
    [ "$bc" = 000 ] && verdict=ERROR
    case "$ac" in 5??) verdict=ERROR ;; esac
    case "$bc" in 5??) verdict=ERROR ;; esac
    case "$al$bl" in *FOREIGN:*) verdict=DIFF ;; esac
    if [ "$ac" != "$bc" ] || [ "$al" != "$bl" ] || [ "${check%-diff}" != "$check" ]; then
        [ "$verdict" = OK ] && verdict=DIFF
    fi
    [ "$verdict" = OK ] || bad=1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$verdict" "$path" "$ac" "$bc" "$al" "$bl" "$check"
done < "$1"
exit "$bad"
