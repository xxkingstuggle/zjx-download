#include <Network/Network.h>
#include <stdint.h>
#include "include/zjx_download_network_shim.h"

int32_t zjx_apply_process_doh(const char *url) {
    if (url == NULL || url[0] == '\0') return 0;
    nw_endpoint_t endpoint = nw_endpoint_create_url(url);
    if (endpoint == NULL) return 0;
    nw_resolver_config_t resolver = nw_resolver_config_create_https(endpoint);
    if (resolver == NULL) {
        nw_release(endpoint);
        return 0;
    }
    nw_privacy_context_require_encrypted_name_resolution(NW_DEFAULT_PRIVACY_CONTEXT, true, resolver);
    nw_release(resolver);
    nw_release(endpoint);
    return 1;
}

void zjx_disable_process_doh(void) {
    nw_privacy_context_require_encrypted_name_resolution(NW_DEFAULT_PRIVACY_CONTEXT, false, NULL);
}
