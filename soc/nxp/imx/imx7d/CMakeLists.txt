#
# Copyright 2017,2024 NXP
#
# SPDX-License-Identifier: Apache-2.0
#

zephyr_sources(
  soc.c
  soc_clk_freq.c
  )

if(CONFIG_OPENAMP_RSC_TABLE)
  zephyr_linker_section(NAME .resource_table GROUP ROM_REGION NOINPUT)
  zephyr_linker_section_configure(SECTION .resource_table KEEP INPUT ".resource_table*")
endif()

set(SOC_LINKER_SCRIPT ${CMAKE_CURRENT_SOURCE_DIR}/linker.ld CACHE INTERNAL "")
