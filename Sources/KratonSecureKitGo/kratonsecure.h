/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2023 KratonSecure Technologies. All Rights Reserved.
 */

#ifndef KRATONSECURE_H
#define KRATONSECURE_H

#include <sys/types.h>
#include <stdint.h>
#include <stdbool.h>

typedef void(*logger_fn_t)(void *context, int level, const char *msg);
extern void kratonSetLogger(void *context, logger_fn_t logger_fn);
extern int kratonTurnOn(const char *settings, int32_t tun_fd);
extern void kratonTurnOff(int handle);
extern int64_t kratonSetConfig(int handle, const char *settings);
extern char *kratonGetConfig(int handle);
extern void kratonBumpSockets(int handle);
extern void kratonDisableSomeRoamingForBrokenMobileSemantics(int handle);
extern const char *kratonVersion();

#endif
