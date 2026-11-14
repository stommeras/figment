; A one-screen roguelike. Walk with the arrows and take the stairs down.
;
; The map is 16 by 15 tiles of 8 by 8 pixels, below a status line that shows the depth.
; It lives at 0x3000 + y * 16 + x, one byte per tile: 0 floor, 1 wall, 2 stairs.
; The other state is at 0x3100: player x, player y, depth tens, depth ones,
; the keys held last frame, and the frames left on the current beep.

        JMP main

; The glyphs are 8 bytes each, one bit per pixel, top row first. They start at 0x0003,
; right after the JMP, because draw_tile computes their address from that number.
        .byte 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00   ; 0 floor
        .byte 0xFE, 0xFE, 0xFE, 0x00, 0xEF, 0xEF, 0xEF, 0x00   ; 1 wall
        .byte 0x03, 0x03, 0x0F, 0x0F, 0x3F, 0x3F, 0xFF, 0xFF   ; 2 stairs
        .byte 0x18, 0x18, 0x7E, 0x18, 0x18, 0x24, 0x42, 0x00   ; 3 player
        .byte 0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00   ; 4 to 13 are the digits 0 to 9
        .byte 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00
        .byte 0x3C, 0x66, 0x06, 0x0C, 0x30, 0x60, 0x7E, 0x00
        .byte 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00
        .byte 0x0C, 0x1C, 0x3C, 0x6C, 0x7E, 0x0C, 0x0C, 0x00
        .byte 0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00
        .byte 0x3C, 0x66, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00
        .byte 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00
        .byte 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00
        .byte 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x66, 0x3C, 0x00

main:   LDI r0, 1
        ST r0, [0x3103]
        CALL new_floor

frame:  CALL tick_beep
        LD r0, [0x3F00]         ; r0 = keys pressed this frame and not the last
        LD r1, [0x3104]
        ST r0, [0x3104]
        XOR r1, 0xFF
        AND r0, r1
        LD r7, [0x3100]
        LD r8, [0x3101]
        MOV r1, r0
        AND r1, 0b0001
        JZ no_up
        SUB r8, 1
        JMP try
no_up:  MOV r1, r0
        AND r1, 0b0010
        JZ no_down
        ADD r8, 1
        JMP try
no_down:
        MOV r1, r0
        AND r1, 0b0100
        JZ no_left
        SUB r7, 1
        JMP try
no_left:
        MOV r1, r0
        AND r1, 0b1000
        JZ done
        ADD r7, 1

; The border is all wall, so a step never leaves the map.
try:    CALL tile_at
        MOV rC, r0
        CMP rC, 1
        JZ bump
        PUSH r7
        PUSH r8
        LD r7, [0x3100]
        LD r8, [0x3101]
        CALL draw_cell
        POP r8
        POP r7
        ST r7, [0x3100]
        ST r8, [0x3101]
        CALL draw_player
        CMP rC, 2
        JNZ done
        CALL descend
        LDI r0, 76
        LDI r1, 10
        CALL beep
        CALL new_floor
        JMP done
bump:   LDI r0, 36
        LDI r1, 4
        CALL beep
done:   ST r0, [0x3F03]
        JMP frame

; Adds one to the depth, from 99 back to 00.
descend:
        LD r0, [0x3103]
        ADD r0, 1
        CMP r0, 10
        JNZ same_tens
        LDI r0, 0
        LD r1, [0x3102]
        ADD r1, 1
        CMP r1, 10
        JNZ tens_ok
        LDI r1, 0
tens_ok:
        ST r1, [0x3102]
same_tens:
        ST r0, [0x3103]
        RET

; Plays note r0 for r1 frames.
beep:   ST r0, [0x3F01]
        ST r1, [0x3105]
        RET

tick_beep:
        LD r0, [0x3105]
        CMP r0, 0
        JZ tick_end
        SUB r0, 1
        ST r0, [0x3105]
        JNZ tick_end
        ST r0, [0x3F01]
tick_end:
        RET

; Fills the map with wall, carves a cave by walking at random from the player's start,
; puts the stairs where the walk ends, and draws everything in the next frame.
new_floor:
        LDI r5, 0x30
        LDI r6, 0
        LDI r0, 1
fill:   ST r0, [r5:r6]
        ADD r6, 1
        CMP r6, 240
        JNZ fill
        LD r7, [0x3F02]         ; start at x 4 to 11, y 3 to 10
        AND r7, 7
        ADD r7, 4
        LD r8, [0x3F02]
        AND r8, 7
        ADD r8, 3
        ST r7, [0x3100]
        ST r8, [0x3101]
walk:   LDI rC, 0               ; 256 steps
carve:  LDI r0, 0
        CALL set_tile
        LD r0, [0x3F02]
        AND r0, 3
        JZ go_up
        CMP r0, 1
        JZ go_down
        CMP r0, 2
        JZ go_left
        CMP r7, 14
        JZ stepped
        ADD r7, 1
        JMP stepped
go_up:  CMP r8, 1
        JZ stepped
        SUB r8, 1
        JMP stepped
go_down:
        CMP r8, 13
        JZ stepped
        ADD r8, 1
        JMP stepped
go_left:
        CMP r7, 1
        JZ stepped
        SUB r7, 1
stepped:
        SUB rC, 1
        JNZ carve
        LD r0, [0x3100]         ; walk on if the walk ended where the player stands
        CMP r0, r7
        JNZ place
        LD r0, [0x3101]
        CMP r0, r8
        JZ walk
place:  LDI r0, 2
        CALL set_tile
        ST r0, [0x3F03]         ; draw in the next frame, which the drawing fills
        CALL draw_map
        CALL draw_player
        JMP draw_status

; r0 = the tile at r7, r8. Uses r5 and r6.
tile_at:
        CALL map_address
        LD r0, [r5:r6]
        RET

; Sets the tile at r7, r8 to r0. Uses r5 and r6.
set_tile:
        CALL map_address
        ST r0, [r5:r6]
        RET

map_address:
        MOV r6, r8
        SHL r6
        SHL r6
        SHL r6
        SHL r6
        ADD r6, r7
        LDI r5, 0x30
        RET

draw_map:
        LDI r8, 0
map_row:
        LDI r7, 0
map_col:
        CALL draw_cell
        ADD r7, 1
        CMP r7, 16
        JNZ map_col
        ADD r8, 1
        CMP r8, 15
        JNZ map_row
        RET

; Draws the map tile at r7, r8. Keeps r7, r8 and rC.
draw_cell:
        CALL tile_at
        CMP r0, 1
        JZ wall_colors
        CMP r0, 2
        JZ stairs_colors
        LDI r1, 0x05
        LDI r2, 0x00
        JMP cell
wall_colors:
        LDI r1, 0x04
        LDI r2, 0x00
        JMP cell
stairs_colors:
        LDI r1, 0x0A
        LDI r2, 0x00
cell:   ADD r8, 1               ; the status line is screen row 0
        CALL draw_tile
        SUB r8, 1
        RET

draw_player:
        LD r7, [0x3100]
        LD r8, [0x3101]
        ADD r8, 1
        LDI r0, 3
        LDI r1, 0x07
        LDI r2, 0x00
        JMP draw_tile

draw_status:
        LDI r7, 0
        LDI r8, 0
        LDI r0, 2
        LDI r1, 0x0A
        LDI r2, 0x00
        CALL draw_tile
        LDI r1, 0x07
        LDI r7, 1
        LD r0, [0x3102]
        ADD r0, 4
        CALL draw_tile
        LDI r7, 2
        LD r0, [0x3103]
        ADD r0, 4
        JMP draw_tile

; Draws glyph r0 in color r1 on color r2 at screen tile r7, r8.
; Keeps r0, r1, r2, r7, r8 and rC. Uses r3, r5, r6 and r9 to rB.
; The pixel loop is unrolled so a new floor draws within one frame.
draw_tile:
        LDI r9, 0               ; r9:rA = 0x0003 + r0 * 8
        MOV rA, r0
        SHL rA
        SHL rA
        SHL rA
        ADD rA, 3
        MOV r5, r8              ; r5:r6 = 0x4000 + r8 * 1024 + r7 * 8
        SHL r5
        SHL r5
        ADD r5, 0x40
        MOV r6, r7
        SHL r6
        SHL r6
        SHL r6
        LDI rB, 8
glyph_row:
        LD r3, [r9:rA]
        CMP r3, 0
        JZ blank_row
        ST r2, [r5:r6]
        SHL r3
        JNC px0
        ST r1, [r5:r6]
px0:    ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC px1
        ST r1, [r5:r6]
px1:    ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC px2
        ST r1, [r5:r6]
px2:    ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC px3
        ST r1, [r5:r6]
px3:    ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC px4
        ST r1, [r5:r6]
px4:    ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC px5
        ST r1, [r5:r6]
px5:    ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC px6
        ST r1, [r5:r6]
px6:    ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC px7
        ST r1, [r5:r6]
px7:    ADD r6, 1
        JMP row_end
blank_row:
        ST r2, [r5:r6]
        ADD r6, 1
        ST r2, [r5:r6]
        ADD r6, 1
        ST r2, [r5:r6]
        ADD r6, 1
        ST r2, [r5:r6]
        ADD r6, 1
        ST r2, [r5:r6]
        ADD r6, 1
        ST r2, [r5:r6]
        ADD r6, 1
        ST r2, [r5:r6]
        ADD r6, 1
        ST r2, [r5:r6]
        ADD r6, 1
row_end:
        SUB r6, 8               ; back to the row start, then down a row
        ADD r6, 128
        ADC r5, 0
        ADD rA, 1
        SUB rB, 1
        JNZ glyph_row
        RET
