<?php
# LocalSettings.php — Asmbly Wiki (MediaWiki 1.43)
#
# This file is configuration-as-code. It is stored in the repo at:
#   config/mediawiki/LocalSettings.php
#
# SECRET INJECTION:
#   Placeholders of the form ${VAR_NAME} are substituted by the Packer build
#   using envsubst. Do NOT commit real secrets here. Required env vars:
#
#   MW_DB_PASSWORD          — MariaDB wiki user password
#   MW_SECRET_KEY           — generate: openssl rand -hex 64
#   MW_UPGRADE_KEY          — generate: openssl rand -hex 16
#   MW_SMTP_PASSWORD        — Gmail app password for notification@asmbly.org
#   MW_DISCOURSE_SECRET     — Discourse SSO shared secret
#
# Derived from the MediaWiki 1.35.8 LocalSettings.php captured in output/info.txt
# and translated to 1.43 conventions. Changes from 1.35:
#   - PluggableAuth v5 flat vars → v7 $wgPluggableAuth_Config array
#   - $wgDBTableOptions charset: binary → utf8mb4
#   - $wgMainCacheType: CACHE_NONE → CACHE_ACCEL (APCu installed)
#   - $wgJobRunRate = 0 (job queue driven by cron, not web requests)
#   - $wgLogos array format (1.35 already had this, carried forward)

# Guard against direct web access
if ( !defined( 'MEDIAWIKI' ) ) {
    exit;
}

# =============================================================================
# Site identity
# =============================================================================

$wgSitename      = "Asmbly Wiki";
$wgMetaNamespace = "Asmbly_Wiki";

$wgServer          = "https://wiki.asmbly.org";
$wgScriptPath      = "";
$wgResourceBasePath = $wgScriptPath;
$wgArticlePath     = "/wiki/$1";
$wgUsePathInfo     = true;

# =============================================================================
# Logos
# =============================================================================

$wgLogo    = "$wgScriptPath/ASMBLY_Avatar_135x135.png";
$wgFavicon = "$wgScriptPath/ASMBLY_Avatar-150x150.png";

$wgLogos = [
    '1x'   => "$wgScriptPath/ASMBLY_Avatar_135x135.png",
    '1.5x' => "$wgScriptPath/ASMBLY_Avatar_202x202.png",
    '2x'   => "$wgScriptPath/ASMBLY_Avatar_270x270.png",
    'icon' => "$wgScriptPath/ASMBLY_Avatar_100x100.png",
    'wordmark' => [
        'src'    => "$wgScriptPath/ASMBLY_WordMark_135x40.png",
        'width'  => 135,
        'height' => 40,
    ],
];

# =============================================================================
# Database
# =============================================================================

$wgDBtype     = "mysql";
$wgDBserver   = "localhost";
$wgDBname     = "mediawiki";
$wgDBuser     = "wiki";
$wgDBpassword = "${MW_DB_PASSWORD}";
$wgDBprefix   = "";

# utf8mb4 everywhere — old server used CHARSET=binary which is a workaround
# for old MariaDB; 10.11 handles utf8mb4 natively
$wgDBTableOptions = "ENGINE=InnoDB, DEFAULT CHARSET=utf8mb4, COLLATE=utf8mb4_unicode_ci";

# =============================================================================
# Security keys  (injected at build time, never committed)
# =============================================================================

$wgSecretKey  = "${MW_SECRET_KEY}";
$wgUpgradeKey = "${MW_UPGRADE_KEY}";

# Changing this logs out all existing sessions — keep stable across upgrades
$wgAuthenticationTokenVersion = "1";

# =============================================================================
# Caching / performance
# =============================================================================

# APCu is installed (php-apcu) — much faster than CACHE_NONE used on old server
$wgMainCacheType    = CACHE_ACCEL;
$wgSessionCacheType = CACHE_DB;
$wgMemCachedServers = [];
$wgUseLocalMessageCache = true;
$wgCacheDirectory = "$IP/cache";

# Job queue driven by cron (/etc/cron.d/mediawiki-jobs), not web requests
$wgJobRunRate = 0;

# =============================================================================
# File uploads
# =============================================================================

$wgEnableUploads   = true;
$wgUploadPath      = "$wgScriptPath/images";
$wgUploadDirectory = "$IP/images";
$wgMaxUploadSize   = 104857600;   # 100 MiB

# Same additional types as 1.35 server
$wgFileExtensions = array_merge(
    $wgFileExtensions,
    [ 'pdf', 'stl', 'lbdev', 'clb' ]
);

# =============================================================================
# Email
# =============================================================================

$wgEnableEmail     = true;
$wgEnableUserEmail = false;

$wgEmergencyContact = "admin@asmbly.org";
$wgPasswordSender   = "admin@asmbly.org";

$wgEnotifUserTalk   = true;
$wgEnotifWatchlist  = true;
$wgEmailAuthentication = false;

# Gmail SMTP relay
$wgSMTP = [
    'host'     => 'ssl://smtp.gmail.com',
    'IDHost'   => 'gmail.com',
    'port'     => 465,
    'username' => 'notification@asmbly.org',
    'password' => '${MW_SMTP_PASSWORD}',
    'auth'     => true,
];

# =============================================================================
# Licensing
# =============================================================================

$wgRightsPage = "";
$wgRightsUrl  = "https://creativecommons.org/licenses/by-nc-sa/4.0/";
$wgRightsText = "Creative Commons Attribution-NonCommercial-ShareAlike";
$wgRightsIcon = "$wgResourceBasePath/resources/assets/licenses/cc-by-nc-sa.png";

# =============================================================================
# Locale
# =============================================================================

$wgLanguageCode = "en";
$wgShellLocale  = "en_US.utf8";
$wgDiff3        = "/usr/bin/diff3";
$wgPingback     = false;
$wgUseInstantCommons = true;

# =============================================================================
# Skins
# =============================================================================

wfLoadSkin( 'Vector' );
wfLoadSkin( 'Timeless' );
wfLoadSkin( 'MonoBook' );
wfLoadSkin( 'MinervaNeue' );
$wgDefaultSkin = "timeless";

# =============================================================================
# Permissions
# =============================================================================

# Anonymous users: read-only, no account creation
$wgGroupPermissions['*']['edit']          = false;
$wgGroupPermissions['*']['createaccount'] = false;
$wgGroupPermissions['*']['createpage']    = false;

# Logged-in users: no edit by default (must be in 'editor' group)
$wgGroupPermissions['user']['edit']       = false;
$wgGroupPermissions['user']['createpage'] = false;

# Editors (Discourse 'makers' and 'community' groups via SSO)
$wgGroupPermissions['editor']['edit']       = true;
$wgGroupPermissions['editor']['createpage'] = true;

# Required for Discourse SSO auto-provisioning
$wgGroupPermissions['*']['autocreateaccount'] = true;

# Sysops cannot override the title blacklist (prevents accidental unlocking)
$wgGroupPermissions['sysop']['tboverride'] = false;

# =============================================================================
# Bundled extensions (shipped with MW 1.43 tarball)
# =============================================================================

wfLoadExtension( 'AbuseFilter' );
wfLoadExtension( 'CategoryTree' );
wfLoadExtension( 'Cite' );
wfLoadExtension( 'CiteThisPage' );
wfLoadExtension( 'CodeEditor' );
wfLoadExtension( 'ConfirmEdit' );
wfLoadExtension( 'DiscussionTools' );
wfLoadExtension( 'Echo' );
wfLoadExtension( 'Gadgets' );
wfLoadExtension( 'ImageMap' );
wfLoadExtension( 'InputBox' );
wfLoadExtension( 'Interwiki' );
wfLoadExtension( 'Linter' );
wfLoadExtension( 'LoginNotify' );
wfLoadExtension( 'Math' );
wfLoadExtension( 'MultimediaViewer' );
wfLoadExtension( 'Nuke' );
wfLoadExtension( 'OATHAuth' );
wfLoadExtension( 'PageImages' );
wfLoadExtension( 'ParserFunctions' );
wfLoadExtension( 'PdfHandler' );
wfLoadExtension( 'Poem' );
wfLoadExtension( 'ReplaceText' );
wfLoadExtension( 'SecureLinkFixer' );
wfLoadExtension( 'SpamBlacklist' );
wfLoadExtension( 'SyntaxHighlight_GeSHi' );
wfLoadExtension( 'TemplateData' );
wfLoadExtension( 'TextExtracts' );
wfLoadExtension( 'Thanks' );
wfLoadExtension( 'TitleBlacklist' );
wfLoadExtension( 'VisualEditor' );
wfLoadExtension( 'WikiEditor' );

# AbuseFilter — rule-based anti-spam/vandalism filters
$wgAbuseFilterActions = [
    'throttle' => true,
    'warn' => true,
    'disallow' => true,
    'blockautopromote' => true,
    'block' => true,
    'tag' => true,
];

# LoginNotify — notifies users of logins from new devices/locations
$wgLoginNotifyUseEcho = true;

# Math — LaTeX formula rendering (useful for electronics/physics pages)
$wgDefaultUserOptions['math'] = 'mathml';

# Lua scripting — required by Infobox, Navbox, and excerpt templates
wfLoadExtension( 'Scribunto' );
$wgScribuntoDefaultEngine = 'luastandalone';
# NOTE: no luaPath override. Neither Scribunto's bundled binaries, LuaBinaries,
# nor LuaJIT (unsupported — phab:T184156) are available for arm64/Graviton.
# 04-mediawiki.sh compiles Lua 5.1.5 from source and installs it at
# Scribunto's own default bundled-binary path, so auto-detection just works.
$wgScribuntoUseCodeEditor = true;

# Per-template CSS — used by common Scribunto modules
wfLoadExtension( 'TemplateStyles' );

# JSON data pages — used for excerpt/tabular templates sourced from Commons
wfLoadExtension( 'JsonConfig' );
$wgJsonConfigEnableLuaSupport = true;
$wgJsonConfigInterwikiPrefix  = "commons";

$wgJsonConfigModels['Tabular.JsonConfig'] = 'JsonConfig\JCTabularContent';
$wgJsonConfigs['Tabular.JsonConfig'] = [
    'namespace' => 486,
    'nsName'    => 'Data',
    'pattern'   => '/.\.tab$/',
    'license'   => 'CC0-1.0',
    'isLocal'   => false,
    'remote'    => [ 'url' => 'https://commons.wikimedia.org/w/api.php' ],
];

$wgJsonConfigModels['Map.JsonConfig'] = 'JsonConfig\JCMapDataContent';
$wgJsonConfigs['Map.JsonConfig'] = [
    'namespace' => 486,
    'nsName'    => 'Data',
    'pattern'   => '/.\.map$/',
    'license'   => 'CC0-1.0',
    'isLocal'   => false,
    'remote'    => [ 'url' => 'https://commons.wikimedia.org/w/api.php' ],
];

# =============================================================================
# Third-party extensions
# =============================================================================

# ── TitleBlacklist ────────────────────────────────────────────────────────────
$wgTitleBlacklistSources = [
    [
        'type' => 'localpage',
        'src'  => 'MediaWiki:Titleblacklist',
    ],
];

# ── WikiCategoryTagCloud — tag cloud on main page ────────────────────────────
wfLoadExtension( 'WikiCategoryTagCloud' );

# ── IFrameTag — embeds iframes (used for restreamer.asmbly.org) ──────────────
wfLoadExtension( 'IFrameTag' );
$iFrameOnWikiConfig = false;
$iFrameDomains = [
    'restreamer.asmbly.org',
];

# ── PluggableAuth v7 + DiscourseSsoConsumer ───────────────────────────────────
#
wfLoadExtension( 'PluggableAuth' );
wfLoadExtension( 'DiscourseSsoConsumer' );

$wgPluggableAuth_Config = [
    'Log In With Discourse' => [ 'plugin' => 'DiscourseSsoConsumer' ],
];

# Uncomment to allow local admin login alongside Discourse SSO:
# $wgPluggableAuth_EnableLocalLogin = true;

# DiscourseSsoConsumer uses a hook-based config (flat globals removed in 6.x).
# See: https://codeberg.org/centertap/DiscourseSsoConsumer#configure-discoursessoconsumer-using-a-hook-function
$wgHooks['DiscourseSsoConsumer_Configure'][] =
    function ( array &$config ) {
        $config['DiscourseUrl']            = 'https://yo.asmbly.org';
        $config['Sso']['Enable']           = true;
        $config['Sso']['SharedSecret']     = '${MW_DISCOURSE_SECRET}';
        $config['Sso']['EnableAutoRelogin'] = true;
        $config['User']['ExposeName']      = true;
        $config['User']['ExposeEmail']     = false;
        # Discourse group → MediaWiki group mapping
        # 'makers' and 'community' → editor
        # 'sysops' and 'leadership' → sysop + bureaucrat
        $config['User']['GroupMaps'] = [
            'editor'     => [ 'makers', 'community' ],
            'sysop'      => [ 'sysops', 'leadership' ],
            'bureaucrat' => [ 'sysops', 'leadership' ],
        ];
        return true;
    };

