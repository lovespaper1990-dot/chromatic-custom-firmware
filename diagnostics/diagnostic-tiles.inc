; Original 5x7 monochrome tiles. Each entry supplies the seven 5-bit rows.
MACRO glyph
    REPT 7
        db (\1) << 2, (\1) << 2
        SHIFT
    ENDR
    db 0, 0
ENDM
Tiles:
    ds 16, 0
    glyph 14, 17, 19, 21, 25, 17, 14 ; 0
    glyph 4, 12, 4, 4, 4, 4, 14 ; 1
    glyph 14, 17, 1, 2, 4, 8, 31 ; 2
    glyph 30, 1, 1, 14, 1, 1, 30 ; 3
    glyph 2, 6, 10, 18, 31, 2, 2 ; 4
    glyph 31, 16, 16, 30, 1, 1, 30 ; 5
    glyph 6, 8, 16, 30, 17, 17, 14 ; 6
    glyph 31, 1, 2, 4, 8, 8, 8 ; 7
    glyph 14, 17, 17, 14, 17, 17, 14 ; 8
    glyph 14, 17, 17, 15, 1, 2, 12 ; 9
    glyph 14, 17, 17, 31, 17, 17, 17 ; A
    glyph 30, 17, 17, 30, 17, 17, 30 ; B
    glyph 14, 17, 16, 16, 16, 17, 14 ; C
    glyph 31, 16, 16, 30, 16, 16, 31 ; E
    glyph 17, 18, 20, 24, 20, 18, 17 ; K
    glyph 17, 27, 21, 21, 17, 17, 17 ; M
    glyph 17, 25, 21, 19, 17, 17, 17 ; N
    glyph 14, 17, 17, 17, 17, 17, 14 ; O
    glyph 30, 17, 17, 30, 16, 16, 16 ; P
    glyph 30, 17, 17, 30, 20, 18, 17 ; R
    glyph 15, 16, 16, 14, 1, 1, 30 ; S
    glyph 31, 4, 4, 4, 4, 4, 4 ; T
    glyph 17, 17, 17, 17, 17, 17, 14 ; U
    ASSERT (@ - Tiles) / 16 == RING_TILE
    glyph 14, 17, 17, 17, 17, 17, 14 ; hollow ring
    ASSERT (@ - Tiles) / 16 == DIAMOND_TILE
    glyph 4, 14, 31, 31, 31, 14, 4 ; filled diamond
TilesEnd:
