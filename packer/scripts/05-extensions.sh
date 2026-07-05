#!/usr/bin/env bash
# packer/scripts/05-extensions.sh
# Phase 5: Install MediaWiki extensions compatible with 1.43 (REL1_43 branch).
#
# EXTENSION STRATEGY:
#   Many extensions that were separate in MW 1.35 are now BUNDLED with the MW 1.43
#   tarball and just need wfLoadExtension() — they do NOT need to be git cloned.
#
#   Bundled in MW 1.43 (no clone needed):
#     CategoryTree, Cite, CiteThisPage, CodeEditor, ConfirmEdit, Gadgets,
#     ImageMap, InputBox, Interwiki, LocalisationUpdate, MultimediaViewer,
#     Nuke, OATHAuth, PageImages, ParserFunctions, PdfHandler, Poem,
#     Renameuser, ReplaceText, SecureLinkFixer, SpamBlacklist,
#     SyntaxHighlight_GeSHi, TemplateData, TextExtracts, TitleBlacklist,
#     VisualEditor, WikiEditor
#
#   Separately installed (Gerrit REL1_43):
#     Scribunto, TemplateStyles, JsonConfig
#
#   Third-party (GitHub):
#     PluggableAuth, DiscourseSsoConsumer, WikiCategoryTagCloud, IFrameTag
#
# HOW TO FIND THE RIGHT VERSION:
#   - https://www.mediawiki.org/wiki/Extension:<name>
#   - Check the "Version matrix" on each extension page
#   - Use `git ls-remote https://gerrit.wikimedia.org/r/mediawiki/extensions/<Ext> 'refs/heads/REL1_43'`

set -euxo pipefail

MW_VERSION="${MW_VERSION:-1.43.0}"
MW_ROOT="/var/www/mediawiki"

# ── Git safe.directory ────────────────────────────────────────────────────────
# The MediaWiki tree is owned by apache:apache (set by 04-mediawiki.sh), but
# this script runs as root.  Git >= 2.35.2 refuses to operate on directories
# owned by a different user unless they are marked safe.
git config --global --add safe.directory '*'

# ── GitHub authentication ─────────────────────────────────────────────────────
# A fine-grained PAT or classic token with read:packages / contents:read scope.
# Injected by Packer as GITHUB_TOKEN; required to clone private/rate-limited repos.
: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"

# Never fall back to an interactive prompt — fail fast if credentials are wrong.
export GIT_TERMINAL_PROMPT=0

# Configure a credential helper so every https://github.com/ operation uses the
# token automatically, without embedding it in each URL.
git config --global credential.helper \
  "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN}; }; f"
EXT_DIR="${MW_ROOT}/extensions"
SKINS_DIR="${MW_ROOT}/skins"
MW_BRANCH="REL${MW_VERSION%.*}"                   # e.g. REL1.43  → REL1_43
MW_BRANCH="${MW_BRANCH//./_}"                      # REL1.43 → REL1_43

GIT_CLONE_OPTS="--depth=1 --recurse-submodules --shallow-submodules"

# ── Extensions from Gerrit (REL1_43 branch) ──────────────────────────────────
# Array of "ExtensionFolderName|branch_or_tag|gerrit_repo_path"
GERRIT_EXTENSIONS=(
  # Lua scripting — required for Infobox/Navbox templates
  "Scribunto|${MW_BRANCH}|extensions/Scribunto"
  # Per-template CSS styling
  "TemplateStyles|${MW_BRANCH}|extensions/TemplateStyles"
  # JSON data pages (required by Scribunto modules that fetch Commons data)
  "JsonConfig|${MW_BRANCH}|extensions/JsonConfig"
  # Auth framework (required for Discourse SSO)
  "PluggableAuth|${MW_BRANCH}|extensions/PluggableAuth"
  # Tag cloud widget used on main page
  "WikiCategoryTagCloud|${MW_BRANCH}|extensions/WikiCategoryTagCloud"
  # Listed in MW 1.43 docs as bundled but absent from the tarball:
  "Renameuser|${MW_BRANCH}|extensions/Renameuser"
  "LocalisationUpdate|${MW_BRANCH}|extensions/LocalisationUpdate"
)

# ── Third-party extensions from GitHub ────────────────────────────────────────
# Array of "ExtensionFolderName|branch|github_url"
GITHUB_EXTENSIONS=(
  # Discourse SSO consumer — authenticates wiki users against Discourse
  "DiscourseSsoConsumer|main|https://github.com/centertap/DiscourseSsoConsumer.git"
  # Allows embedding iframes (used for restreamer.asmbly.org)
  "IFrameTag|master|https://github.com/hexmode/mediawiki-iframe.git"
)

# Skins to install alongside Vector (which is bundled)
SKINS=(
  "Timeless|${MW_BRANCH}|skins/Timeless"
  "MonoBook|${MW_BRANCH}|skins/MonoBook"
)

GERRIT_BASE_URL="https://gerrit.wikimedia.org/r/mediawiki"

# ── Helper: clone or update a repo ───────────────────────────────────────────
clone_or_update() {
  local dest="$1" url="$2" branch="$3"
  if [ -d "${dest}/.git" ]; then
    echo "  Updating $(basename "${dest}") …"
    git -C "${dest}" fetch origin "${branch}" --depth=1 2>&1 | tail -2
    git -C "${dest}" checkout "${branch}" 2>/dev/null || git -C "${dest}" checkout -b "${branch}" "origin/${branch}"
    git -C "${dest}" submodule update --init --recursive --depth=1
  else
    # Directory exists but is not a git repo (partial/failed previous run) — wipe it.
    [ -d "${dest}" ] && { echo "  Removing stale directory $(basename "${dest}") …"; rm -rf "${dest}"; }
    echo "  Cloning $(basename "${dest}") @ ${branch} …"
    git clone ${GIT_CLONE_OPTS} --branch "${branch}" "${url}" "${dest}" 2>&1 | tail -3
  fi
}

# ── Clone Gerrit extensions ───────────────────────────────────────────────────
echo "Installing Gerrit extensions for MediaWiki ${MW_VERSION} (branch ${MW_BRANCH})"
for entry in "${GERRIT_EXTENSIONS[@]}"; do
  IFS='|' read -r name branch repo_path <<< "${entry}"
  dest="${EXT_DIR}/${name}"
  url="${GERRIT_BASE_URL}/${repo_path}"
  clone_or_update "${dest}" "${url}" "${branch}"
done

# ── Clone GitHub extensions ───────────────────────────────────────────────────
echo "Installing GitHub extensions"
for entry in "${GITHUB_EXTENSIONS[@]}"; do
  IFS='|' read -r name branch url <<< "${entry}"
  dest="${EXT_DIR}/${name}"
  clone_or_update "${dest}" "${url}" "${branch}"
done

# ── Clone skins ───────────────────────────────────────────────────────────────
echo "Installing extra skins"
for entry in "${SKINS[@]}"; do
  IFS='|' read -r name branch repo_path <<< "${entry}"
  dest="${SKINS_DIR}/${name}"
  url="${GERRIT_BASE_URL}/${repo_path}"
  clone_or_update "${dest}" "${url}" "${branch}"
done

# ── Append wfLoadExtension() calls to LocalSettings.php ──────────────────────
LSETTINGS="${MW_ROOT}/LocalSettings.php"
{
  echo ""
  echo "# === Bundled extensions (shipped with MW 1.43 tarball) ==="
  echo "# Note: Renameuser and LocalisationUpdate are NOT in the 1.43 tarball"
  echo "# despite documentation — they are cloned via GERRIT_EXTENSIONS above."
  echo "wfLoadExtension( 'CategoryTree' );"
  echo "wfLoadExtension( 'Cite' );"
  echo "wfLoadExtension( 'CiteThisPage' );"
  echo "wfLoadExtension( 'CodeEditor' );"
  echo "wfLoadExtension( 'ConfirmEdit' );"
  echo "wfLoadExtension( 'Gadgets' );"
  echo "wfLoadExtension( 'ImageMap' );"
  echo "wfLoadExtension( 'InputBox' );"
  echo "wfLoadExtension( 'Interwiki' );"
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
  echo "wfLoadExtension( 'TitleBlacklist' );"
  echo "wfLoadExtension( 'VisualEditor' );"
  echo "wfLoadExtension( 'WikiEditor' );"
  echo ""
  echo "# === Bundled extensions enabled beyond the MW 1.35 baseline ==="
  echo "# These ship with the MW 1.43 tarball and are safe to enable on first launch."
  echo ""
  echo "# Echo — in-wiki notification system (required by DiscussionTools & Thanks)"
  echo "wfLoadExtension( 'Echo' );"
  echo ""
  echo "# DiscussionTools — structured talk pages (replaces legacy talk page UI)"
  echo "wfLoadExtension( 'DiscussionTools' );"
  echo ""
  echo "# Thanks — one-click editor appreciation (requires Echo)"
  echo "wfLoadExtension( 'Thanks' );"
  echo ""
  echo "# AbuseFilter — rule-based anti-spam/vandalism filters"
  echo "wfLoadExtension( 'AbuseFilter' );"
  echo "\$wgAbuseFilterActions = ['throttle' => true, 'warn' => true, 'disallow' => true,"
  echo "    'blockautopromote' => true, 'block' => true, 'tag' => true];"
  echo ""
  echo "# LoginNotify — notifies users of logins from new devices/locations"
  echo "wfLoadExtension( 'LoginNotify' );"
  echo "\$wgLoginNotifyUseEcho = true;"
  echo ""
  echo "# Linter — detects deprecated or broken wiki markup"
  echo "wfLoadExtension( 'Linter' );"
  echo ""
  echo "# Math — LaTeX formula rendering (useful for electronics/physics pages)"
  echo "wfLoadExtension( 'Math' );"
  echo "\$wgDefaultUserOptions['math'] = 'mathml';"
  echo ""
  echo "# === Separately installed extensions ==="
  for entry in "${GERRIT_EXTENSIONS[@]}" ; do
    IFS='|' read -r name branch repo_path <<< "${entry}"
    ext_dir="${EXT_DIR}/${name}"
    if [ -f "${ext_dir}/extension.json" ]; then
      echo "wfLoadExtension( '${name}' );"
    fi
  done
  for entry in "${GITHUB_EXTENSIONS[@]}" ; do
    IFS='|' read -r name branch url <<< "${entry}"
    ext_dir="${EXT_DIR}/${name}"
    if [ -f "${ext_dir}/extension.json" ]; then
      echo "wfLoadExtension( '${name}' );"
    fi
  done
  echo ""
  echo "# === Extra skins ==="
  for entry in "${SKINS[@]}"; do
    IFS='|' read -r name branch repo_path <<< "${entry}"
    skin_dir="${SKINS_DIR}/${name}"
    if [ -f "${skin_dir}/skin.json" ]; then
      echo "wfLoadSkin( '${name}' );"
    fi
  done
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

# ── Fix ownership ─────────────────────────────────────────────────────────────
chown -R apache:apache "${EXT_DIR}" "${SKINS_DIR}"

# ── Composer dependencies for extensions that need it ─────────────────────────
if ! command -v composer &>/dev/null; then
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
  rm -f composer-setup.php
fi

# Composer 2.2+ blocks plugins unless explicitly allowed.
# composer/installers is the standard MediaWiki extension install-path plugin.
composer global config --no-plugins allow-plugins.composer/installers true

for ext_dir in "${EXT_DIR}"/*/; do
  if [ -f "${ext_dir}composer.json" ] && [ ! -d "${ext_dir}vendor" ]; then
    echo "  Running composer install in $(basename "${ext_dir}") …"
    composer install --no-dev --no-interaction --working-dir="${ext_dir}"
  fi
done

echo "05-extensions.sh complete"
