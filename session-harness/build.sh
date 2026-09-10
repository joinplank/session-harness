#!/usr/bin/env bash
# Build the artifacts for the session-harness plugin.
#
# Produces in dist/:
#   1. <skill>.zip per skill — one-by-one install (unzip into ~/.claude/skills/).
#      Currently: adversarial-review.zip, harness-setup.zip.
#   2. session-harness.plugin (a zip) — the whole bundle: manifest, commands, skills,
#      scripts. ONE-file install via the plugin manager.
#
# CANONICAL SOURCE: this bundle. The repo root's scripts/, .claude/commands/ and .claude/skills/
# are a SYNCED COPY written by the sync step below, so the repo dogfoods what it ships and the
# vendored layout is exercised on every build. Never hand-edit the copy; edit the bundle.
#
# Validates and TESTS before writing anything. Any failure aborts with dist/ and the repo-root
# copy untouched — a half-passing build must not ship, nor become the harness this repo runs on.
#
# Run from anywhere; cd's relative to its own location.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SKILLS="$HERE/skills"
DIST="$HERE/dist"
TESTS="$HERE/tests"
PLUGIN_MANIFEST="$HERE/.claude-plugin/plugin.json"
MARKETPLACE_MANIFEST="$REPO_ROOT/.claude-plugin/marketplace.json"

DESCRIPTION_MAX_CHARS=1024

validation_failed=0

# -----------------------------------------------------------------------------
# Skills — a skill whose frontmatter name disagrees with its folder is invoked under
# a name the manifest never registered, so it installs and then cannot be called.
# -----------------------------------------------------------------------------
echo "Validating skills..."

for skill_dir in "$SKILLS"/*/; do
  skill_name="$(basename "$skill_dir")"
  skill_md="$skill_dir/SKILL.md"

  if [ ! -f "$skill_md" ]; then
    echo "  ✗ $skill_name: SKILL.md missing" >&2; validation_failed=1; continue
  fi
  # The description is a YAML folded scalar spanning lines, so take everything between
  # `description:` and the next top-level key.
  description=$(awk '
    /^description:/ { collecting = 1; sub(/^description:[[:space:]]*>?-?[[:space:]]*/, ""); if ($0 != "") print; next }
    collecting && /^[a-zA-Z-]+:/ { exit }
    collecting { print }
  ' "$skill_md" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  if [ -z "$description" ]; then
    echo "  ✗ $skill_name: description missing in frontmatter" >&2; validation_failed=1; continue
  fi
  desc_len=${#description}
  if [ "$desc_len" -gt "$DESCRIPTION_MAX_CHARS" ]; then
    echo "  ✗ $skill_name: description $desc_len chars (limit $DESCRIPTION_MAX_CHARS)" >&2; validation_failed=1; continue
  fi
  name=$(awk '/^name: /{sub(/^name: /,""); print; exit}' "$skill_md")
  if [ "$name" != "$skill_name" ]; then
    echo "  ✗ $skill_name: frontmatter name '$name' != folder '$skill_name'" >&2; validation_failed=1; continue
  fi
  echo "  ✓ $skill_name (description $desc_len chars)"
done

# -----------------------------------------------------------------------------
# Frontmatter has to parse as real YAML — the folded descriptions above are the easiest
# thing in this bundle to break, and a skill with unparseable frontmatter simply does not
# load. python3 ships no stdlib YAML, so prefer `ruby -ryaml` (bundled with macOS) and fall
# back to PyYAML; skip loudly rather than fail the build when neither exists.
# -----------------------------------------------------------------------------
echo "Validating frontmatter parses as YAML..."
yaml_parser=""
if command -v ruby > /dev/null 2>&1 && ruby -ryaml -e '' > /dev/null 2>&1; then
  yaml_parser="ruby"
elif python3 -c "import yaml" > /dev/null 2>&1; then
  yaml_parser="python3-yaml"
fi
if [ -z "$yaml_parser" ]; then
  echo "  ! no YAML parser on PATH (ruby -ryaml / python3's yaml module) — skipping frontmatter validation" >&2
else
  frontmatter_failed=0
  while IFS= read -r -d '' f; do
    head -n1 "$f" | grep -q '^---$' || continue
    fm_ok=1
    if [ "$yaml_parser" = "ruby" ]; then
      awk 'NR==1{next} /^---$/{exit} {print}' "$f" | ruby -ryaml -e 'YAML.load(STDIN.read)' > /dev/null 2>&1 || fm_ok=0
    else
      awk 'NR==1{next} /^---$/{exit} {print}' "$f" | python3 -c 'import sys, yaml; yaml.safe_load(sys.stdin.read())' > /dev/null 2>&1 || fm_ok=0
    fi
    if [ "$fm_ok" -eq 0 ]; then
      echo "  ✗ ${f#"$HERE"/}: frontmatter failed to parse as YAML" >&2
      validation_failed=1; frontmatter_failed=1
    fi
  done < <(find "$HERE/skills" "$HERE/commands" -type f -name '*.md' -print0)
  [ "$frontmatter_failed" -eq 0 ] && echo "  ✓ frontmatter parses as YAML (via $yaml_parser)"
fi

# -----------------------------------------------------------------------------
# Every command must declare a description: it is the only thing a user sees in the
# slash-command list, and a command without one installs invisibly.
# -----------------------------------------------------------------------------
echo "Validating commands..."
for cmd in "$HERE"/commands/*.md; do
  [ -f "$cmd" ] || continue
  if head -n1 "$cmd" | grep -q '^---$' && awk 'NR>1 && /^---$/{exit} NR>1' "$cmd" | grep -q '^description:'; then
    echo "  ✓ $(basename "$cmd")"
  else
    echo "  ✗ $(basename "$cmd"): missing frontmatter description" >&2; validation_failed=1
  fi
done

# -----------------------------------------------------------------------------
# Shell — parse, then actually run the suites. `bash -n` is a syntax check only, and every
# real failure mode of these scripts (empty-array expansion under set -u on stock macOS
# bash 3.2, a substitution that ends the script at exit 128 with nothing on stderr) is
# invisible to it.
# -----------------------------------------------------------------------------
echo "Validating shell scripts parse..."
for s in "$HERE"/scripts/*.sh "$HERE"/skills/*/*.sh "$TESTS"/*.sh; do
  [ -f "$s" ] || continue
  if bash -n "$s" 2>/dev/null; then
    echo "  ✓ $(basename "$s")"
  else
    echo "  ✗ $(basename "$s"): syntax error" >&2; validation_failed=1
  fi
done

# Bash 3.2 (stock macOS) crashes under `set -u` on a bare "${arr[@]}" when the array is
# empty; the fix is the ${arr[@]+"${arr[@]}"} guard. Flag any shipped script still on the
# bare form.
echo "Linting for the bash 3.2 empty-array trap under set -u..."
empty_array_failed=0
while IFS= read -r -d '' f; do
  grep -Eq '^[[:space:]]*set +-[a-zA-Z]*u' "$f" || continue
  while IFS=: read -r lineno line; do
    case "$line" in
      *'[@]+"'*) continue ;;
    esac
    echo "  ✗ ${f#"$HERE"/}:$lineno: bare \"\${arr[@]}\" under set -u — use \${arr[@]+\"\${arr[@]}\"}" >&2
    validation_failed=1; empty_array_failed=1
  done < <(grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}' "$f" || true)
done < <(find "$HERE/scripts" "$HERE/skills" -type f -name '*.sh' -print0)
[ "$empty_array_failed" -eq 0 ] && echo "  ✓ no bare empty-array expansions under set -u"

echo "Running test suites..."
for suite in "$TESTS"/*.test.sh; do
  [ -f "$suite" ] || continue
  case "$(basename "$suite")" in
    model-call.test.sh) target="$HERE/scripts/model-call.sh";;
    run-review.test.sh) target="$HERE/skills/adversarial-review/run-review.sh";;
    *)                  target="";;
  esac
  if /bin/bash "$suite" ${target:+"$target"} 2>&1 | sed 's/^/  /'; then
    :
  else
    echo "  ✗ $(basename "$suite") failed" >&2; validation_failed=1
  fi
done

# -----------------------------------------------------------------------------
# Manifests. A plugin.json that is merely plugin-SHAPED still fails `/plugin install`, so
# `claude plugin validate` is a fatal gate wherever the CLI exists.
# -----------------------------------------------------------------------------
echo "Validating plugin manifest..."
if [ ! -f "$PLUGIN_MANIFEST" ]; then
  echo "  ✗ .claude-plugin/plugin.json missing" >&2; validation_failed=1
elif ! python3 -c "import json; json.load(open('$PLUGIN_MANIFEST'))" 2>/dev/null; then
  echo "  ✗ plugin.json is not valid JSON" >&2; validation_failed=1
else
  manifest_check=$(python3 - "$PLUGIN_MANIFEST" "$HERE" <<'PYEOF'
import json, os, sys
manifest_path, bundle_root = sys.argv[1], sys.argv[2]
data = json.load(open(manifest_path))
errors = []
if not data.get("name"):
    errors.append("missing 'name'")
# Every skills entry must be "./"-relative and exist: a path that is merely present in the
# array registers a skill the install then cannot find.
for entry in data.get("skills", []):
    if not entry.startswith("./"):
        errors.append(f"skills entry '{entry}' must start with './'")
    elif not os.path.isdir(os.path.join(bundle_root, entry)):
        errors.append(f"skills entry '{entry}' does not exist")
# 'repository' is a string URL in this schema, never an npm-style object.
if "repository" in data and not isinstance(data["repository"], str):
    errors.append("'repository' must be a string URL")
print("ERR:" + "; ".join(errors) if errors else "OK")
PYEOF
)
  if [[ "$manifest_check" == ERR:* ]]; then
    echo "  ✗ plugin.json: ${manifest_check#ERR:}" >&2; validation_failed=1
  else
    pname=$(python3 -c "import json; print(json.load(open('$PLUGIN_MANIFEST'))['name'])")
    pver=$(python3 -c "import json; print(json.load(open('$PLUGIN_MANIFEST'))['version'])")
    echo "  ✓ plugin manifest: $pname v$pver"
  fi
fi

echo "Validating repo-root marketplace manifest..."
if [ ! -f "$MARKETPLACE_MANIFEST" ]; then
  echo "  ✗ .claude-plugin/marketplace.json missing at repo root" >&2; validation_failed=1
elif ! python3 -c "import json; json.load(open('$MARKETPLACE_MANIFEST'))" 2>/dev/null; then
  echo "  ✗ marketplace.json is not valid JSON" >&2; validation_failed=1
else
  mp_check=$(python3 - "$MARKETPLACE_MANIFEST" "$REPO_ROOT" <<'PYEOF'
import json, os, sys
manifest_path, repo_root = sys.argv[1], sys.argv[2]
data = json.load(open(manifest_path))
errors = [f"missing top-level '{k}'" for k in ("name", "owner", "plugins") if k not in data]
if not errors:
    for entry in data["plugins"]:
        ename = entry.get("name", "<unnamed>")
        source = entry.get("source", "")
        if not source.startswith("./"):
            errors.append(f"{ename}: source '{source}' must be a relative './...' path")
            continue
        if not os.path.isdir(os.path.join(repo_root, source)):
            errors.append(f"{ename}: source dir '{source}' does not exist")
        # The marketplace entry's name must match the bundle's own plugin.json name, or the
        # install resolves to a plugin the manifest never described.
        bundle_manifest = os.path.join(repo_root, source, ".claude-plugin", "plugin.json")
        if os.path.isfile(bundle_manifest):
            bundle_name = json.load(open(bundle_manifest)).get("name")
            if bundle_name != ename:
                errors.append(f"{ename}: plugin.json name is '{bundle_name}'")
print("ERR:" + "; ".join(errors) if errors else "OK")
PYEOF
)
  if [[ "$mp_check" == ERR:* ]]; then
    echo "  ✗ marketplace.json: ${mp_check#ERR:}" >&2; validation_failed=1
  else
    mpname=$(python3 -c "import json; print(json.load(open('$MARKETPLACE_MANIFEST'))['name'])")
    echo "  ✓ marketplace manifest: $mpname"
  fi
fi

if command -v claude > /dev/null 2>&1; then
  # BOTH manifests, because the CLI validates whichever one the target directory holds: the repo
  # root is the marketplace, the bundle is the plugin. Validating only the root would leave the
  # plugin.json — the manifest an install actually reads — unchecked, which is how a
  # plugin-SHAPED-but-uninstallable bundle ships.
  echo "Running 'claude plugin validate' (fatal — blocks the build on manifest errors)..."
  validate_log="$(mktemp -t claude-plugin-validate.XXXXXX)"
  for target in "marketplace:$REPO_ROOT" "plugin:$HERE"; do
    label="${target%%:*}"; dir="${target#*:}"
    if ! (cd "$dir" && claude plugin validate . > "$validate_log" 2>&1); then
      echo "  ✗ claude plugin validate reported errors in the $label manifest:" >&2
      sed 's/^/    /' "$validate_log" >&2
      validation_failed=1
    else
      echo "  ✓ claude plugin validate passed ($label)"
    fi
  done
  rm -f "$validate_log"
else
  echo "  ! 'claude' CLI not on PATH — skipping 'claude plugin validate' (install manifests unverified)" >&2
fi

if [ "$validation_failed" -ne 0 ]; then
  echo; echo "BUILD ABORTED: validation failed. dist/ and the repo-root harness left untouched." >&2; exit 1
fi

# -----------------------------------------------------------------------------
# Sync the validated bundle into the repo's own harness — the only exercise the VENDORED layout
# gets, so it runs on every build rather than when a maintainer remembers.
# -----------------------------------------------------------------------------
echo "Syncing bundle → the repo's own harness..."
mkdir -p "$REPO_ROOT/scripts" "$REPO_ROOT/.claude/commands" "$REPO_ROOT/.claude/skills"
rsync -a --delete --exclude '.DS_Store' "$HERE/scripts/"  "$REPO_ROOT/scripts/"
rsync -a --delete --exclude '.DS_Store' "$HERE/commands/" "$REPO_ROOT/.claude/commands/"
rsync -a --delete --exclude '.DS_Store' "$HERE/skills/adversarial-review/" "$REPO_ROOT/.claude/skills/adversarial-review/"
echo "  ✓ scripts/, .claude/commands/, .claude/skills/adversarial-review/ synced"

# run-review.sh resolves model-call.sh by walking up from its own location, and the two layouts
# sit at different depths — so prove the copy works from where it now sits.
echo "Proving the vendored layout resolves its helper..."
# Sourcing happens before argument checking, so reaching an argument error at all is the proof.
# Asserting the positive AND the negative: a future refactor that reordered the two would let a
# usage error pass while the helper went missing, which is the regression this exists to catch.
vendored_out="$(cd "$REPO_ROOT" && bash "$REPO_ROOT/.claude/skills/adversarial-review/run-review.sh" --round abc 2>&1 || true)"
if printf '%s' "$vendored_out" | grep -q 'must be a positive integer' \
   && ! printf '%s' "$vendored_out" | grep -q 'missing model-call.sh'; then
  echo "  ✓ the vendored run-review.sh loads model-call.sh and reaches argument checking"
else
  echo "  ✗ the vendored run-review.sh could not resolve model-call.sh:" >&2
  printf '%s\n' "$vendored_out" | sed 's/^/    /' >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Build — only reached when everything above passed.
# -----------------------------------------------------------------------------
mkdir -p "$DIST"
rm -f "$DIST"/*.zip "$DIST"/*.plugin

cd "$SKILLS"
for skill in */; do
  skill_name="${skill%/}"
  echo "Building skill zip: $skill_name.zip"
  zip -r "$DIST/$skill_name.zip" "$skill_name" \
    -x "*.DS_Store" "*/.git/*" "*/.idea/*" "*/__pycache__/*" > /dev/null
done

cd "$HERE"
echo "Building plugin bundle: session-harness.plugin"
# scripts/ ships INSIDE the plugin: the commands invoke it through ${CLAUDE_PLUGIN_ROOT},
# and run-review.sh sources model-call.sh from it, so a bundle without it installs a harness
# whose every call fails on the first command.
zip -r "$DIST/session-harness.plugin" \
  .claude-plugin \
  commands \
  skills \
  scripts \
  README.md \
  CHANGELOG.md \
  LICENSE \
  -x "*.DS_Store" "*/.git/*" "*/.idea/*" "*/__pycache__/*" > /dev/null

echo
echo "Done. Built artifacts:"
ls -lh "$DIST"
