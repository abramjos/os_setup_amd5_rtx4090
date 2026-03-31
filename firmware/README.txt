AMD Raphael iGPU Firmware — linux-firmware tag 20250509
========================================================

This directory contains firmware blobs for the AMD Raphael iGPU (GC 10.3.6 / DCN 3.1.5)
extracted from linux-firmware git tag 20250509.

CONFIRMED WORKING: DMUB firmware version 0x05002000 (0.0.32.0) — eliminates DCN ring timeouts.

Files present (12 total):
  amdgpu/dcn_3_1_5_dmcub.bin        Display Core Microblaze (CRITICAL — fixes crash loop)
  amdgpu/gc_10_3_6_ce.bin            GFX Constant Engine
  amdgpu/gc_10_3_6_me.bin            GFX Micro Engine
  amdgpu/gc_10_3_6_mec.bin           GFX Micro Engine Compute
  amdgpu/gc_10_3_6_mec2.bin          GFX Micro Engine Compute 2
  amdgpu/gc_10_3_6_pfp.bin           GFX Pre-Fetch Parser
  amdgpu/gc_10_3_6_rlc.bin           GFX RunList Controller
  amdgpu/psp_13_0_5_toc.bin          Platform Security Processor TOC
  amdgpu/psp_13_0_5_ta.bin           PSP Trust Application
  amdgpu/psp_13_0_5_asd.bin          PSP Application Security Driver
  amdgpu/sdma_5_2_6.bin              System DMA
  amdgpu/vcn_3_1_2.bin               Video Core Next

IMPORTANT — .bin vs .bin.zst conflict:
  Ubuntu 24.04 has CONFIG_FW_LOADER_COMPRESS_ZSTD=y — kernel loads .bin.zst FIRST.
  These are .bin files. The install-firmware.sh script handles compression automatically.
  Run: sudo bash script/diag-v2/install-firmware.sh
