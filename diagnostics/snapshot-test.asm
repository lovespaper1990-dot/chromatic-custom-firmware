; Original 32 KiB ROM-only cartridge for cold-boot snapshot verification.
; Build in this directory with RGBDS 1.0.4:
; rgbasm -o /tmp/snapshot-test.o snapshot-test.asm
; rgblink -p 0 -o snapshot-test.gb /tmp/snapshot-test.o
; rgbfix -v -p 0 -t "SNAP TEST" snapshot-test.gb

DEF rP1   EQU $ff00
DEF rLCDC EQU $ff40
DEF rSCY  EQU $ff42
DEF rSCX  EQU $ff43
DEF rLY   EQU $ff44
DEF rBGP  EQU $ff47
DEF BG_MAP EQU $9800
DEF DIGIT_TILE EQU 1
DEF RING_TILE EQU 24
DEF DIAMOND_TILE EQU 25

SECTION "Header", ROM0[$0100]
    nop
    jp Boot
    ds $0150 - @, 0

SECTION "Program", ROM0[$0150]
Boot:
    di
    ld sp, $fffe
    ldh a, [rLCDC]
    bit 7, a
    jr z, .lcdOff
.waitVBlank:
    ldh a, [rLY]
    cp 144
    jr c, .waitVBlank
.lcdOff:
    xor a
    ldh [rLCDC], a
    ldh [rSCX], a
    ldh [rSCY], a
    ld [wCount], a
    ldh [hMarker], a
    ldh [hLastButtons], a

    ld de, Tiles
    ld hl, $8000
    ld bc, TilesEnd - Tiles
.copyTiles:
    ld a, [de]
    inc de
    ld [hli], a
    dec bc
    ld a, b
    or c
    jr nz, .copyTiles

    ld hl, BG_MAP
    ld bc, 32 * 32
.clearMap:
    xor a
    ld [hli], a
    dec bc
    ld a, b
    or c
    jr nz, .clearMap

    ld de, Title
    ld hl, BG_MAP + 3 * 32 + 5
    call DrawText
    ld de, CountLabel
    ld hl, BG_MAP + 7 * 32 + 4
    call DrawText
    ld de, MarkerLabel
    ld hl, BG_MAP + 10 * 32 + 4
    call DrawText
    ld de, Controls
    ld hl, BG_MAP + 15 * 32 + 2
    call DrawText
    call DrawValues
    ld a, $e4
    ldh [rBGP], a
    ld a, $91 ; LCD on, unsigned tiles, background on
    ldh [rLCDC], a
.frame:
    ; Wait for a fresh VBlank, allowing enough time to write three map cells.
    ldh a, [rLY]
    cp 144
    jr nc, .frame
.wait:
    ldh a, [rLY]
    cp 144
    jr c, .wait

    ld a, $10 ; select A, B, Select, Start
    ldh [rP1], a
    REPT 3
        ldh a, [rP1]
    ENDR
    cpl
    and 3
    ld b, a
    ldh a, [hLastButtons]
    cpl
    and b
    ld c, a ; rising edges
    ld a, b
    ldh [hLastButtons], a
    ld a, $30
    ldh [rP1], a

    bit 0, c
    jr z, .checkMarker
    ld a, [wCount]
    add 1
    daa ; packed BCD wraps 99 to 00
    ld [wCount], a
.checkMarker:
    bit 1, c
    jr z, .draw
    ldh a, [hMarker]
    xor 1
    ldh [hMarker], a
.draw:
    call DrawValues
    jr .frame

DrawValues:
    ld a, [wCount]
    ld b, a
    swap a
    and $0f
    add DIGIT_TILE
    ld hl, BG_MAP + 7 * 32 + 13
    ld [hli], a
    ld a, b
    and $0f
    add DIGIT_TILE
    ld [hl], a
    ldh a, [hMarker]
    add RING_TILE
    ld [BG_MAP + 10 * 32 + 13], a
    ret

DrawText:
    ld a, [de]
    inc de
    cp $ff
    ret z
    ld [hli], a
    jr DrawText

CHARMAP " ", 0
CHARMAP "A", 11
CHARMAP "B", 12
CHARMAP "C", 13
CHARMAP "E", 14
CHARMAP "K", 15
CHARMAP "M", 16
CHARMAP "N", 17
CHARMAP "O", 18
CHARMAP "P", 19
CHARMAP "R", 20
CHARMAP "S", 21
CHARMAP "T", 22
CHARMAP "U", 23
Title:       db "SNAP TEST", $ff
CountLabel:  db "COUNT", $ff
MarkerLabel: db "MARK", $ff
Controls:    db "A COUNT   B MARK", $ff

INCLUDE "diagnostic-tiles.inc"

SECTION "Counter", WRAM0[$c000]
wCount: ds 1

SECTION "Marker and input", HRAM[$ff80]
hMarker: ds 1
hLastButtons: ds 1
