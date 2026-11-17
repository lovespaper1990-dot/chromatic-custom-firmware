# Audio snapshot follow-up

`fpga/esp32t/src/rtl/EMU/CORE/gbc_snd.vhd:206–207` instantiates
`iREG_SAVESTATE_Wave1_GBC` / `Wave2_GBC` using the regular `Wave1` / `Wave2`
register descriptors and their same live BACK data. The register map separately
reserves addresses 35/36 for the GBC wave words, but these instances currently
alias 33/34. Their duplicate capture outputs are identical, so OR aggregation
is idempotent; addresses 35/36 currently capture zero.

This was observed during resource review, not changed in the palette read-path
optimization. Before correcting it, establish intended DMG/GBC wave-RAM capture
and restore behavior, add coverage for the distinct words and audio continuation,
and measure resource/routing impact. Do not claim current tests cover that gap.
