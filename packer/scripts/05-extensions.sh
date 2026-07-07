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

set -euxo pipefail

MW_VERSION="${MW_VERSION:-1.43.9}"
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
: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"

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

composer update --no-dev --no-interaction --prefer-dist --optimize-autoloader
echo "Composer update completed successfully"

EXPECTED_EXTENSIONS=("TemplateStyles" "DiscourseSsoConsumer" "IFrameTag" "PluggableAuth" "JsonConfig" "WikiCategoryTagCloud")
for ext in "${EXPECTED_EXTENSIONS[@]}"; do
  if [ ! -d "${EXT_DIR}/${ext}" ]; then
    echo "ERROR: Expected extension ${ext} not found in ${EXT_DIR}"
    exit 1
  fi
done

# ── Fix ownership ─────────────────────────────────────────────────────────────
chown -R apache:apache "${EXT_DIR}"

# ── Append extension loading to LocalSettings.php ─────────────────────────────
LSETTINGS="${MW_ROOT}/LocalSettings.php"
{
  echo ""
  echo "# === Bundled extensions (shipped with MW 1.43 tarball) ==="
  echo "wfLoadExtension( 'AbuseFilter' );"
  echo "wfLoadExtension( 'CategoryTree' );"
  echo "wfLoadExtension( 'Cite' );"
  echo "wfLoadExtension( 'CiteThisPage' );"
  echo "wfLoadExtension( 'CodeEditor' );"
  echo "wfLoadExtension( 'ConfirmEdit' );"
  echo "wfLoadExtension( 'DiscussionTools' );"
  echo "wfLoadExtension( 'Echo' );"
  echo "wfLoadExtension( 'Gadgets' );"
  echo "wfLoadExtension( 'ImageMap' );"
  echo "wfLoadExtension( 'InputBox' );"
  echo "wfLoadExtension( 'Interwiki' );"
  echo "wfLoadExtension( 'Linter' );"
  echo "wfLoadExtension( 'LoginNotify' );"
  echo "wfLoadExtension( 'Math' );"
  echo "wfLoadExtension( 'MultimediaViewer' );"
  echo "wfLoadExtension( 'Nuke' );"
  echo "wfLoadExtension( 'OATHAuth' );"
  echo "wfLoadExtension( 'PageImages' );"
  echo "wfLoadExtension( 'ParserFunctions' );"
  echo "wfLoadExtension( 'PdfHandler' );"
  echo "wfLoadExtension( 'Poem' );"
  echo "wfLoadExtension( 'ReplaceText' );"
  echo "wfLoadExtension( 'SecureLinkFixer' );"
  echo "wfLoadExtension( 'SpamBlacklist' );"
  echo "wfLoadExtension( 'SyntaxHighlight_GeSHi' );"
  echo "wfLoadExtension( 'TemplateData' );"
  echo "wfLoadExtension( 'TextExtracts' );"
  echo "wfLoadExtension( 'Thanks' );"
  echo "wfLoadExtension( 'TitleBlacklist' );"
  echo "wfLoadExtension( 'VisualEditor' );"
  echo "wfLoadExtension( 'WikiEditor' );"
  echo ""
  echo "# AbuseFilter — rule-based anti-spam/vandalism filters"
  echo "\$wgAbuseFilterActions = ['throttle' => true, 'warn' => true, 'disallow' => true,"
  echo "    'blockautopromote' => true, 'block' => true, 'tag' => true];"
  echo ""
  echo "# LoginNotify — notifies users of logins from new devices/locations"
  echo "\$wgLoginNotifyUseEcho = true;"
  echo ""
  echo "# Math — LaTeX formula rendering (useful for electronics/physics pages)"
  echo "\$wgDefaultUserOptions['math'] = 'mathml';"
  echo ""
  echo "# === Extensions installed via Composer (composer.local.json) ==="
  for item in "${EXPECTED_EXTENSIONS[@]}"; do
    echo "wfLoadExtension( '${item}' );"
  done
  echo ""
  echo "# === Skins (all four ship with the MW 1.43 tarball) ==="
  echo "# Vector is the default and loaded automatically."
  echo "wfLoadSkin( 'MonoBook' );"
  echo "wfLoadSkin( 'Timeless' );"
  echo "wfLoadSkin( 'MinervaNeue' );"
  echo ""
  echo "# === Extension configuration ==="
  echo ""
  echo "# Scribunto (Lua)"
  echo "\$wgScribuntoDefaultEngine = 'luastandalone';"
  echo "\$wgScribuntoEngineConf['luastandalone']['luaPath'] = '/usr/bin/lua';"
  echo "\$wgScribuntoUseCodeEditor = true;"
  echo ""
  echo "# JsonConfig — data pages from Commons"
  echo "\$wgJsonConfigEnableLuaSupport = true;"
  echo "\$wgJsonConfigModels['Tabular.JsonConfig'] = 'JsonConfig\\\\JCTabularContent';"
  echo "\$wgJsonConfigs['Tabular.JsonConfig'] = ["
  echo "    'namespace' => 486,"
  echo "    'nsName' => 'Data',"
  echo "    'pattern' => '/.\.tab$/',"
  echo "    'license' => 'CC0-1.0',"
  echo "    'isLocal' => false,"
  echo "];"
  echo "\$wgJsonConfigModels['Map.JsonConfig'] = 'JsonConfig\\\\JCMapDataContent';"
  echo "\$wgJsonConfigs['Map.JsonConfig'] = ["
  echo "    'namespace' => 486,"
  echo "    'nsName' => 'Data',"
  echo "    'pattern' => '/.\.map$/',"
  echo "    'license' => 'CC0-1.0',"
  echo "    'isLocal' => false,"
  echo "];"
  echo "\$wgJsonConfigInterwikiPrefix = 'commons';"
  echo "\$wgJsonConfigs['Tabular.JsonConfig']['remote'] = ["
  echo "    'url' => 'https://commons.wikimedia.org/w/api.php'"
  echo "];"
  echo "\$wgJsonConfigs['Map.JsonConfig']['remote'] = ["
  echo "    'url' => 'https://commons.wikimedia.org/w/api.php'"
  echo "];"
  echo ""
  echo "# TitleBlacklist"
  echo "\$wgGroupPermissions['sysop']['tboverride'] = false;"
  echo "\$wgTitleBlacklistSources = ["
  echo "  ["
  echo "    'type' => 'localpage',"
  echo "    'src'  => 'MediaWiki:Titleblacklist'"
  echo "  ]"
  echo "];"
  echo ""
  echo "# WikiCategoryTagCloud"
  echo "# (no additional config needed — just loads)"
  echo ""
  echo "# IFrameTag"
  echo "\$iFrameOnWikiConfig = false;"
  echo "\$iFrameDomains = ["
  echo "  'restreamer.asmbly.org'"
  echo "];"
  echo ""
  echo "# PluggableAuth + DiscourseSsoConsumer"
  echo "# NOTE: PluggableAuth v7.x for MW 1.39+ uses a different config format."
  echo "# The restore script will merge the old Discourse SSO settings."
  echo "# Uncomment and configure after verifying DiscourseSsoConsumer compatibility:"
  echo "# \$wgPluggableAuth_EnableLocalLogin = false;"
  echo "# \$wgPluggableAuth_ButtonLabelMessage = 'Log In With Discourse';"
} >> "${LSETTINGS}"


echo "05-extensions.sh complete"
