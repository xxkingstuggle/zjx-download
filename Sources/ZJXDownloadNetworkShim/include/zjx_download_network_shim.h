#ifndef ZJX_DOWNLOAD_NETWORK_SHIM_H
#define ZJX_DOWNLOAD_NETWORK_SHIM_H

#include <stdint.h>

int32_t zjx_apply_process_doh(const char *url);
void zjx_disable_process_doh(void);

#endif
