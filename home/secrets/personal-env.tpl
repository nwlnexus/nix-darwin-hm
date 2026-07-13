OP_SERVICE_ACCOUNT_TOKEN="{{ op://Dev/6a2a2bygcy4h56khkhbkfovqxq/credential }}"
GITHUB_PERSONAL_ACCESS_TOKEN="{{ op://Dev/3hwptanyvn7stnz63n5urtdwo4/gh_pat_classic }}"
# moneta bearer token for the mnemosyne dual-write writer (checks this env first,
# then ~/.config/moneta/token). See nwlnexus/moneta#7.
MONETA_AUTH_TOKEN="{{ op://Dev/moneta/auth_token }}"
# Cloudflare Access Service Auth — required at the edge once moneta-access is live.
CF_ACCESS_CLIENT_ID="{{ op://Dev/moneta-svc-auth/username }}"
CF_ACCESS_CLIENT_SECRET="{{ op://Dev/moneta-svc-auth/credential }}"
