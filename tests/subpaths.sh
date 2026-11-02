#!/usr/bin/env bash
# `import github("AndreBaltazar8/abla-soap/...")` against this working tree: what [exports] lists is what src has, each builds, and
# the rest is refused.
set -euo pipefail

compiler=${1:-ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$root/build"
work=$(mktemp -d "$root/build/subpaths.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
export ABLA_PACKAGE_CACHE=$work/cache GIT_CONFIG_GLOBAL=$work/gitconfig

fail() { printf 'subpaths: %s\n' "$1" >&2; exit 1; }

listed=$(sed -n 's/^"[^"]*" = "\(.*\)"$/\1/p' "$root/abla.toml" | sort)
found=$(cd "$root" && find src -name '*.ab' ! -name soap.ab | sort)
[[ $listed == "$found" ]] || { diff <(echo "$listed") <(echo "$found") >&2 || true; fail '[exports] and src differ'; }

# github() goes to a copy of what's here, committed.
package=$work/package
mkdir "$package"
cp -r "$root/abla.toml" "$root/src" "$package/"
git -C "$package" init --quiet --initial-branch=main
git -C "$package" add -A
git -C "$package" -c user.name=t -c user.email=t@example.invalid commit --quiet -m c
git config --file "$GIT_CONFIG_GLOBAL" url."$package".insteadOf https://github.com/AndreBaltazar8/abla-soap.git

app() { # name, main.ab on stdin
    mkdir -p "$work/$1/src"
    printf 'name = "%s"\nversion = "0.1.0"\nentry = "src/main.ab"\n' "$1" > "$work/$1/abla.toml"
    cat > "$work/$1/src/main.ab"
}

while read -r path; do
    app "one-$path" <<AB
import github("AndreBaltazar8/abla-soap/$path")
fun main: int = 0
AB
    "$compiler" package update --project "$work/one-$path" >/dev/null
    "$compiler" build --project "$work/one-$path" -o "$work/one-$path/out" --fast >/dev/null || fail "$path doesn't build"
done < <(sed -n 's/^"\([^"]*\)" = ".*"$/\1/p' "$root/abla.toml")

# The whole package, as a program uses it: envelopes and a client from one import, with abla-xml's names.
app whole <<AB
import github("AndreBaltazar8/abla-soap")
fun main: int {
    var w = soapWriter()
    w.startBody()
    w.xml.element("a", "b")
    if (soapParse(w.finish().text).succeeded) 0 else 1
}
AB
"$compiler" package update --project "$work/whole" >/dev/null
"$compiler" build --project "$work/whole" -o "$work/whole/out" --fast || fail "the package doesn't build"
"$work/whole/out" || fail "the package exited $?"

app private <<AB
import github("AndreBaltazar8/abla-soap/src/envelope")
fun main: int = 0
AB
log=$work/private.log
if "$compiler" package update --project "$work/private" > "$log" 2>&1 && "$compiler" build --project "$work/private" -o "$work/private/out" >> "$log" 2>&1; then
    fail 'an unlisted path was not refused'
fi
grep -qF E_PACKAGE_SUBPATH "$log" || { cat "$log" >&2; fail 'not refused as a subpath'; }
echo 'subpaths: passed'
