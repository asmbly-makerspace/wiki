#!/usr/bin/env bash
# packer/scripts/05-extensions.sh
# Phase 5: Install MediaWiki extensions compatible with 1.43 (REL1_43 branch).
#
# INSTALLATION STRATEGY:
#   This script uses Composer (the dependency manager bundled with MediaWiki's
#   ecosystem) to install extensions, following MediaWiki best practices:
#     - https://www.mediawiki.org/wiki/Composer/For_extensions
#     - https://www.mediawiki.org/wiki/Manual:Composer.json_best_practices
#
#   Key principle: NEVER modify MediaWiki's composer.json directly.
#   Instead, extensions are declared in composer.local.json which is merged
#   automatically by the wikimedia/composer-merge-plugin already configured
#   in MediaWiki core's composer.json.
#
# EXTENSION CATEGORIES:
#
#   Bundled in MW 1.43 (no installation needed — just wfLoadExtension):
#   AbuseFilter CategoryTree Cite CiteThisPage CodeEditor ConfirmEdit
#   DiscussionTools Echo Gadgets ImageMap InputBox Interwiki Linter
#   LoginNotify Math MultimediaViewer Nuke OATHAuth PageImages
#   ParserFunctions PdfHandler Poem README ReplaceText Scribunto
#   SecureLinkFixer SpamBlacklist SyntaxHighlight_GeSHi TemplateData
#   TextExtracts Thanks TitleBlacklist VisualEditor WikiEditor
#
#   Installed via Composer (composer.local.json):
#     DiscourseSsoConsumer (-> PluggableAuth), IFrameTag
#     TemplateStyles, JsonConfig, PluggableAuth, WikiCategoryTagCloud
#
#   NOTE: TemplateStyles, JsonConfig, and WikiCategoryTagCloud are declared as
#   "package" repositories (not "vcs") in composer.local.json because their
#   upstream composer.json files lack a "name" field.  Composer's "vcs" driver
#   requires a name to resolve the package and skips branches without one
#   ("Unknown package has no name defined").  The "package" type lets us supply
#   the metadata inline, bypassing that requirement entirely.
#
# HOW TO ADD/UPDATE AN EXTENSION:
#   1. Add a VCS repository entry in config/mediawiki/composer.local.json
#   2. Add the package "require" line with the correct version constraint
#   3. For Gerrit extensions: use "dev-REL1_XX" matching the MW branch
#   4. For tagged releases: use the semver tag (e.g. "5.0.2")
#   5. Run this script (or `composer update --no-dev` in the MW root)
#   6. Add the corresponding wfLoadExtension()/config to
#      config/mediawiki/LocalSettings.php — the ONLY place extension loading
#      and configuration is defined. This script does not write to
#      LocalSettings.php; it only installs code into extensions/.

set -euxo pipefail

: "${MW_VERSION:?MW_VERSION must be set}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
MW_ROOT="/var/www/mediawiki"
EXT_DIR="${MW_ROOT}/extensions"
MW_BRANCH="REL${MW_VERSION%.*}"                   # e.g. REL1.43  → REL1_43
MW_BRANCH="${MW_BRANCH//./_}"                      # REL1.43 → REL1_43

# ── Git safe.directory ────────────────────────────────────────────────────────
# The MediaWiki tree is owned by apache:apache (set by 04-mediawiki.sh), but
# this script runs as root.  Git >= 2.35.2 refuses to operate on directories
# owned by a different user unless they are marked safe.
git config --global --add safe.directory '*'

# ── GitHub/Codeberg authentication ───────────────────────────────────────────
# A fine-grained PAT or classic token with read:packages / contents:read scope.
# Injected by Packer as GITHUB_TOKEN; used for rate limiting on public repos
# and required for any private repositories.

# Never fall back to an interactive prompt — fail fast if credentials are wrong.
export GIT_TERMINAL_PROMPT=0

# Configure a credential helper so every https://github.com/ operation uses the
# token automatically, without embedding it in each URL.
git config --global credential.helper \
  "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN}; }; f"

# ── Install Composer ──────────────────────────────────────────────────────────
# MediaWiki ships composer.json and vendor/ but not the Composer binary itself.
# Install it globally so we can manage extensions via composer.local.json.
if ! command -v composer &>/dev/null; then
  echo "Installing Composer…"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
  rm -f composer-setup.php
fi

composer --version

# Composer 2.2+ blocks plugins unless explicitly allowed.
# These are required by MediaWiki's Composer setup:
#   - composer/installers: routes packages to extensions/ or skins/ by type
#   - wikimedia/composer-merge-plugin: merges composer.local.json into resolution
composer global config --no-plugins allow-plugins.composer/installers true
composer global config --no-plugins allow-plugins.wikimedia/composer-merge-plugin true

# Configure GitHub OAuth token for Composer (avoids rate limiting on API calls).
composer config --global github-oauth.github.com "${GITHUB_TOKEN}"

# ── Deploy composer.local.json ────────────────────────────────────────────────
# The template is committed to the repo at config/mediawiki/composer.local.json
# uploaded to /tmp/config/ by Packer's file provisioner.
COMPOSER_LOCAL_SRC="/tmp/config/mediawiki/composer.local.json"
COMPOSER_LOCAL_DEST="${MW_ROOT}/composer.local.json"

if [ ! -f "${COMPOSER_LOCAL_SRC}" ]; then
  echo "ERROR: composer.local.json not found at ${COMPOSER_LOCAL_SRC}"
  echo "Ensure Packer's file provisioner uploads config/ to /tmp/config/"
  exit 1
fi

cp "${COMPOSER_LOCAL_SRC}" "${COMPOSER_LOCAL_DEST}"
chown root:apache "${COMPOSER_LOCAL_DEST}"
chmod 644 "${COMPOSER_LOCAL_DEST}"

# ── Run Composer update ───────────────────────────────────────────────────────
# This resolves all requirements from composer.local.json:
#   - Downloads extensions into extensions/ (via composer/installers)
#   - Resolves PHP library dependencies for each extension
#   - Updates vendor/autoload.php
#
# Flags:
#   --no-dev          — skip development dependencies (testing, linting, etc.)
#   --no-interaction  — never prompt; fail on ambiguity
#   --prefer-dist     — download zip archives instead of full git clones where possible
#   --optimize-autoloader — generate optimized class maps for production
echo "Running Composer to install extensions for MediaWiki ${MW_VERSION} (branch ${MW_BRANCH})…"
cd "${MW_ROOT}"

# Temporarily grant write access for Composer to install into extensions/
chown -R root:root "${MW_ROOT}"

# Tell Composer the exact version of the root package (mediawiki/core).
export COMPOSER_ROOT_VERSION="${MW_VERSION}"

# Packer provisioner scripts run as root. Composer 2.x disables all plugins in
# non-interactive root sessions unless this is set. Plugins are required:
#   - composer/installers      routes packages to extensions/ by type
#   - wikimedia/composer-merge-plugin  merges composer.local.json
# This is safe here — we are intentionally running as root in a build image.
export COMPOSER_ALLOW_SUPERUSER=1

composer update --no-dev --no-interaction --prefer-dist --optimize-autoloader
echo "Composer update completed successfully"

# ── Patch DiscourseSsoConsumer 5.0.2 for MW 1.37+ ────────────────────────────
# DB_MASTER was renamed to DB_PRIMARY in MW 1.37 and removed in 1.42.
# The 6.x release that fixed this requires PHP 8.4, which MW 1.43 does not
# support. Patch the installed source directly; DB_PRIMARY has the same value.
# TODO: [16-Jul-2026 04:01:55 UTC] PHP Deprecated:  Use of wfGetDB was deprecated in MediaWiki 1.39. [Called from MediaWiki\Extension\DiscourseSsoConsumer\Db::ensureCurrentSchema in /var/www/mediawiki/extensions/DiscourseSsoConsumer/src/Db.php at line 83] in /var/www/mediawiki/includes/debug/MWDebug.php on line 385
echo "Patching DiscourseSsoConsumer: DB_MASTER → DB_PRIMARY"
grep -rl --include='*.php' 'DB_MASTER' "${EXT_DIR}/DiscourseSsoConsumer" \
  | xargs sed -i 's/\bDB_MASTER\b/DB_PRIMARY/g'

EXPECTED_EXTENSIONS=("TemplateStyles" "DiscourseSsoConsumer" "IFrameTag" "PluggableAuth" "JsonConfig" "WikiCategoryTagCloud")
for ext in "${EXPECTED_EXTENSIONS[@]}"; do
  if [ ! -d "${EXT_DIR}/${ext}" ]; then
    echo "ERROR: Expected extension ${ext} not found in ${EXT_DIR}"
    exit 1
  fi
done

# ── Fix ownership ─────────────────────────────────────────────────────────────
chown -R apache:apache "${EXT_DIR}"

# NOTE: extension loading (wfLoadExtension/wfLoadSkin) and all extension
# configuration live SOLELY in config/mediawiki/LocalSettings.php — the
# single source of truth deployed by 04-mediawiki.sh.

echo "05-extensions.sh complete"
