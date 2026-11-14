; A one-screen roguelike. Walk with the arrows, walk into monsters to hit them,
; and take the stairs down. At 0 HP the run ends, and an arrow starts a new one.
;
; The map is 16 by 15 tiles of 8 by 8 pixels, below a status line that shows the depth and HP.
; It holds one byte per tile at MAP + y * 16 + x.

KEYS = 0x3F00
BEEP = 0x3F01
RAND = 0x3F02
FRAME = 0x3F03
SCREEN = 0x4000

; The rogue test in src/asm.zig reads MAP and the state up to DEPTH_ONES at these addresses.
MAP = 0x3000
PLAYER_X = 0x3100
PLAYER_Y = 0x3101
DEPTH_TENS = 0x3102
DEPTH_ONES = 0x3103
KEYS_BEFORE = 0x3104            ; the keys held last frame
KEYS_DRAWING = 0x3105           ; the keys held while a new floor was drawn
BEEP_FRAMES = 0x3106            ; the frames left on the current beep
PLAYER_HP = 0x3107
DEAD = 0x3108                   ; 1 once the player is at 0 HP
MONSTER_X = 0x3110              ; MONSTERS bytes each, one per monster
MONSTER_Y = 0x3114
MONSTER_HP = 0x3118             ; 0 for a monster that is dead or not on this floor

MONSTERS = 4
MAX_HP = 9
MONSTER_MAX_HP = 2

MAP_TILES = 240
FLOOR = 0                       ; the tiles, which are also their glyph numbers
WALL = 1
STAIRS = 2
PLAYER = 3                      ; the other glyphs
DIGIT_0 = 4
MONSTER = 14
HEART = 15

UP = 0b0001
DOWN = 0b0010
LEFT = 0b0100
ARROWS = 0b1111

BLACK = 0x0
BROWN = 0x4
SLATE = 0x5
WHITE = 0x7
RED = 0x8
GREEN = 0xB
YELLOW = 0xA

NOTE_BUMP = 36
NOTE_STAIRS = 76
NOTE_HIT = 60
NOTE_HURT = 30
NOTE_DEAD = 20

main:   LDI r0, 0
        ST r0, [DEPTH_TENS]
        ST r0, [DEAD]
        LDI r0, 1
        ST r0, [DEPTH_ONES]
        LDI r0, MAX_HP
        ST r0, [PLAYER_HP]
        CALL new_floor

frame:  CALL tick_beep
        LD rC, [KEYS]           ; rC = arrows pressed this frame and not the last
        LD r1, [KEYS_DRAWING]   ; with the keys held while a new floor was drawn
        OR rC, r1
        LDI r1, 0
        ST r1, [KEYS_DRAWING]
        LD r1, [KEYS_BEFORE]
        ST rC, [KEYS_BEFORE]
        XOR r1, 0xFF
        AND rC, r1
        AND rC, ARROWS
        JZ .done
        LD r0, [DEAD]           ; after a death, an arrow starts a new run
        CMP r0, 0
        JNZ main
        LD r7, [PLAYER_X]
        LD r8, [PLAYER_Y]
        CALL draw_cell          ; erase the player, who is drawn again below
        MOV r1, rC
        AND r1, UP
        JZ .no_up
        SUB r8, 1
        JMP .try
.no_up: MOV r1, rC
        AND r1, DOWN
        JZ .no_down
        ADD r8, 1
        JMP .try
.no_down:
        MOV r1, rC
        AND r1, LEFT
        JZ .right
        SUB r7, 1
        JMP .try
.right: ADD r7, 1

; The border is all wall, so a step never leaves the map.
.try:   CALL monster_at
        CMP r4, MONSTERS
        JNZ .attack
        CALL tile_at
        CMP r0, WALL
        JZ .bump
        ST r7, [PLAYER_X]
        ST r8, [PLAYER_Y]
        CMP r0, STAIRS
        JZ .stairs
        CALL draw_player
        JMP .monsters
.attack:
        LDI r5, hi(MONSTER_HP)
        LDI r6, lo(MONSTER_HP)
        ADD r6, r4
        LD r0, [r5:r6]
        SUB r0, 1
        ST r0, [r5:r6]
        JNZ .hit
        CALL draw_cell          ; erase the monster
.hit:   CALL draw_player
        LDI r0, NOTE_HIT
        LDI r1, 3
        CALL beep
.monsters:
        CALL monsters_turn
        JMP .done
.stairs:
        CALL descend
        CALL heal
        LDI r0, NOTE_STAIRS
        LDI r1, 10
        CALL beep
        CALL new_floor
        JMP .done
.bump:  CALL draw_player
        LDI r0, NOTE_BUMP
        LDI r1, 4
        CALL beep
.done:  ST r0, [FRAME]
        JMP frame

; Adds one to the depth and stops at 99.
descend:
        LD r0, [DEPTH_ONES]
        LD r1, [DEPTH_TENS]
        CMP r0, 9
        JNZ .ones
        CMP r1, 9
        JZ .end
        ADD r1, 1
        ST r1, [DEPTH_TENS]
        LDI r0, 0
        ST r0, [DEPTH_ONES]
        RET
.ones:  ADD r0, 1
        ST r0, [DEPTH_ONES]
.end:   RET

; Each live monster hits the player when next to them, or else steps toward them.
monsters_turn:
        LDI rD, 0
.next:  LDI r5, hi(MONSTER_HP)
        LDI r6, lo(MONSTER_HP)
        ADD r6, rD
        LD r0, [r5:r6]
        CMP r0, 0
        JZ .skip
        CALL monster_turn
        LD r0, [DEAD]
        CMP r0, 0
        JNZ .end
.skip:  ADD rD, 1
        CMP rD, MONSTERS
        JNZ .next
.end:   RET

; The turn of monster rD. Keeps rD.
monster_turn:
        LDI r5, hi(MONSTER_X)
        LDI r6, lo(MONSTER_X)
        ADD r6, rD
        LD r7, [r5:r6]
        LDI r6, lo(MONSTER_Y)
        ADD r6, rD
        LD r8, [r5:r6]
        LD rE, [PLAYER_X]       ; rE, rF = the player's position minus the monster's
        SUB rE, r7
        LD rF, [PLAYER_Y]
        SUB rF, r8
        MOV r0, rF              ; next to the player when one is 0 and the other 1 or -1
        CMP rE, 0
        JZ .near
        CMP rF, 0
        JNZ .step
        MOV r0, rE
.near:  ADD r0, 1               ; 1 and -1 become 2 and 0, the only values AND 0xFD clears
        AND r0, 0xFD
        JZ .hit
.step:  MOV r1, r7
        MOV r2, r8
        CMP rE, 0
        JZ .try_y
        AND rE, 0x80
        JZ .right
        SUB r7, 1
        JMP .try_x
.right: ADD r7, 1
.try_x: CALL free
        JZ .move
        MOV r7, r1
.try_y: CMP rF, 0
        JZ .end
        AND rF, 0x80
        JZ .down
        SUB r8, 1
        JMP .try_y2
.down:  ADD r8, 1
.try_y2:
        CALL free
        JNZ .end
.move:  MOV rE, r7
        MOV rF, r8
        MOV r7, r1
        MOV r8, r2
        CALL draw_cell
        MOV r7, rE
        MOV r8, rF
        LDI r5, hi(MONSTER_X)
        LDI r6, lo(MONSTER_X)
        ADD r6, rD
        ST r7, [r5:r6]
        LDI r6, lo(MONSTER_Y)
        ADD r6, rD
        ST r8, [r5:r6]
        JMP draw_monster
.hit:   LD r0, [PLAYER_HP]
        SUB r0, 1
        ST r0, [PLAYER_HP]
        JZ die
        LDI r0, NOTE_HURT
        LDI r1, 6
        CALL beep
        JMP draw_status
.end:   RET

; Sets Z when a monster can step onto r7, r8, which has no wall and no other monster.
; Uses r0 and r4 to r6. A step never lands on the player, who is never next to a monster that steps.
free:   CALL tile_at
        CMP r0, WALL
        JZ .wall
        CALL monster_at
        CMP r4, MONSTERS
        RET
.wall:  CMP r0, 0
        RET

die:    LDI r0, 1
        ST r0, [DEAD]
        CALL draw_status
        LD r7, [PLAYER_X]
        LD r8, [PLAYER_Y]
        ADD r8, 1
        LDI r0, PLAYER
        LDI r1, RED
        CALL draw_tile
        LDI r0, NOTE_DEAD
        LDI r1, 30
        JMP beep

heal:   LD r0, [PLAYER_HP]
        CMP r0, MAX_HP
        JZ .end
        ADD r0, 1
        ST r0, [PLAYER_HP]
.end:   RET

; Plays note r0 for r1 frames.
beep:   ST r0, [BEEP]
        ST r1, [BEEP_FRAMES]
        RET

tick_beep:
        LD r0, [BEEP_FRAMES]
        CMP r0, 0
        JZ .end
        SUB r0, 1
        ST r0, [BEEP_FRAMES]
        JNZ .end
        ST r0, [BEEP]
.end:   RET

; Fills the map with wall, carves a cave by walking at random from the player's start,
; puts the stairs where the walk ends, and draws everything in the next frame.
new_floor:
        LDI r5, hi(MAP)
        LDI r6, lo(MAP)
        LDI r0, WALL
.fill:  ST r0, [r5:r6]
        ADD r6, 1
        CMP r6, MAP_TILES
        JNZ .fill
        LD r7, [RAND]           ; start at x 4 to 11, y 3 to 10
        AND r7, 7
        ADD r7, 4
        LD r8, [RAND]
        AND r8, 7
        ADD r8, 3
        ST r7, [PLAYER_X]
        ST r8, [PLAYER_Y]
.walk:  LDI rC, 0               ; 256 steps
.carve: LDI r0, FLOOR
        CALL set_tile
        LD r0, [RAND]
        AND r0, 3
        JZ .up
        CMP r0, 1
        JZ .down
        CMP r0, 2
        JZ .left
        CMP r7, 14
        JZ .stepped
        ADD r7, 1
        JMP .stepped
.up:    CMP r8, 1
        JZ .stepped
        SUB r8, 1
        JMP .stepped
.down:  CMP r8, 13
        JZ .stepped
        ADD r8, 1
        JMP .stepped
.left:  CMP r7, 1
        JZ .stepped
        SUB r7, 1
.stepped:
        SUB rC, 1
        JNZ .carve
        LD r0, [PLAYER_X]       ; walk on if the walk ended where the player stands
        CMP r0, r7
        JNZ .place
        LD r0, [PLAYER_Y]
        CMP r0, r8
        JZ .walk
.place: LDI r0, STAIRS
        CALL set_tile
        CALL place_monsters
        ST r0, [FRAME]          ; draw in the next frame, which the drawing fills
        CALL tick_beep
        LD r0, [KEYS]           ; the main loop reads this frame's keys next frame
        ST r0, [KEYS_DRAWING]
        CALL draw_map
        CALL draw_monsters
        CALL draw_player
        JMP draw_status

; Puts as many monsters as the depth, up to MONSTERS, on random floor tiles
; outside the 5 by 5 tiles around the player.
place_monsters:
        LDI r5, hi(MONSTER_HP)
        LDI r6, lo(MONSTER_HP)
        LDI r0, 0
        LDI rD, MONSTERS
.clear: ST r0, [r5:r6]
        ADD r6, 1
        SUB rD, 1
        JNZ .clear
        LD rC, [DEPTH_ONES]     ; rC = the number of monsters
        LD r0, [DEPTH_TENS]
        CMP r0, 0
        JNZ .all
        CMP rC, MONSTERS
        JC .count
.all:   LDI rC, MONSTERS
.count: LDI rE, 0               ; give up after 256 tries, in a cave too small for them all
.try:   SUB rE, 1
        JZ .end
        LD r7, [RAND]
        AND r7, 15
        LD r8, [RAND]
        AND r8, 15
        CMP r8, 15
        JZ .try
        CALL tile_at
        CMP r0, FLOOR
        JNZ .try
        CALL monster_at
        CMP r4, MONSTERS
        JNZ .try
        LD r0, [PLAYER_X]       ; far enough when x or y is 3 or more away
        SUB r0, r7
        ADD r0, 2
        CMP r0, 5
        JNC .far
        LD r0, [PLAYER_Y]
        SUB r0, r8
        ADD r0, 2
        CMP r0, 5
        JC .try
.far:   LDI r5, hi(MONSTER_X)
        LDI r6, lo(MONSTER_X)
        ADD r6, rD
        ST r7, [r5:r6]
        LDI r6, lo(MONSTER_Y)
        ADD r6, rD
        ST r8, [r5:r6]
        LDI r6, lo(MONSTER_HP)
        ADD r6, rD
        LDI r0, MONSTER_MAX_HP
        ST r0, [r5:r6]
        ADD rD, 1
        CMP rD, rC
        JNZ .try
.end:   RET

; r4 = the number of the live monster at r7, r8, or MONSTERS if there is none.
; Uses r0, r5 and r6.
monster_at:
        LDI r4, 0
        LDI r5, hi(MONSTER_X)
.next:  LDI r6, lo(MONSTER_HP)
        ADD r6, r4
        LD r0, [r5:r6]
        CMP r0, 0
        JZ .skip
        LDI r6, lo(MONSTER_X)
        ADD r6, r4
        LD r0, [r5:r6]
        CMP r0, r7
        JNZ .skip
        LDI r6, lo(MONSTER_Y)
        ADD r6, r4
        LD r0, [r5:r6]
        CMP r0, r8
        JZ .end
.skip:  ADD r4, 1
        CMP r4, MONSTERS
        JNZ .next
.end:   RET

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

; r5:r6 = MAP + r8 * 16 + r7. MAP starts a 256-byte page, so the high byte stays.
map_address:
        MOV r6, r8
        SHL r6
        SHL r6
        SHL r6
        SHL r6
        ADD r6, r7
        LDI r5, hi(MAP)
        RET

draw_map:
        LDI r8, 0
.row:   LDI r7, 0
.cell:  CALL draw_cell
        ADD r7, 1
        CMP r7, 16
        JNZ .cell
        ADD r8, 1
        CMP r8, 15
        JNZ .row
        RET

; Draws the map tile at r7, r8. Keeps r7, r8 and rC.
draw_cell:
        CALL tile_at
        CMP r0, WALL
        JZ .wall
        CMP r0, STAIRS
        JZ .stairs
        LDI r1, SLATE
        JMP .draw
.wall:  LDI r1, BROWN
        JMP .draw
.stairs:
        LDI r1, YELLOW
.draw:  ADD r8, 1               ; the status line is screen row 0
        CALL draw_tile
        SUB r8, 1
        RET

draw_monsters:
        LDI rD, 0
.next:  LDI r5, hi(MONSTER_HP)
        LDI r6, lo(MONSTER_HP)
        ADD r6, rD
        LD r0, [r5:r6]
        CMP r0, 0
        JZ .skip
        LDI r6, lo(MONSTER_X)
        ADD r6, rD
        LD r7, [r5:r6]
        LDI r6, lo(MONSTER_Y)
        ADD r6, rD
        LD r8, [r5:r6]
        CALL draw_monster
.skip:  ADD rD, 1
        CMP rD, MONSTERS
        JNZ .next
        RET

; Draws a monster at map tile r7, r8.
draw_monster:
        ADD r8, 1
        LDI r0, MONSTER
        LDI r1, GREEN
        JMP draw_tile

draw_player:
        LD r7, [PLAYER_X]
        LD r8, [PLAYER_Y]
        ADD r8, 1
        LDI r0, PLAYER
        LDI r1, WHITE
        JMP draw_tile

draw_status:
        LDI r7, 0
        LDI r8, 0
        LDI r0, STAIRS
        LDI r1, YELLOW
        CALL draw_tile
        LDI r1, WHITE
        LDI r7, 1
        LD r0, [DEPTH_TENS]
        ADD r0, DIGIT_0
        CALL draw_tile
        LDI r7, 2
        LD r0, [DEPTH_ONES]
        ADD r0, DIGIT_0
        CALL draw_tile
        LDI r7, 14
        LDI r0, HEART
        LDI r1, RED
        CALL draw_tile
        LDI r7, 15
        LDI r1, WHITE
        LD r0, [PLAYER_HP]
        ADD r0, DIGIT_0
        JMP draw_tile

; Draws glyph r0 in color r1 on black at screen tile r7, r8.
; Keeps r0, r1, r7, r8 and rC. Uses r2, r3, r5, r6 and r9 to rB.
; The pixel loop is unrolled so a new floor draws within one frame.
draw_tile:
        LDI r2, BLACK
        MOV rA, r0              ; r9:rA = glyphs + r0 * 8
        SHL rA
        SHL rA
        SHL rA
        LDI r9, hi(glyphs)
        ADD rA, lo(glyphs)
        ADC r9, 0
        MOV r5, r8              ; r5:r6 = SCREEN + r8 * 1024 + r7 * 8
        SHL r5
        SHL r5
        ADD r5, hi(SCREEN)
        MOV r6, r7
        SHL r6
        SHL r6
        SHL r6
        LDI rB, 8
.row:   LD r3, [r9:rA]
        CMP r3, 0
        JZ .blank
        ST r2, [r5:r6]
        SHL r3
        JNC .px0
        ST r1, [r5:r6]
.px0:   ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC .px1
        ST r1, [r5:r6]
.px1:   ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC .px2
        ST r1, [r5:r6]
.px2:   ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC .px3
        ST r1, [r5:r6]
.px3:   ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC .px4
        ST r1, [r5:r6]
.px4:   ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC .px5
        ST r1, [r5:r6]
.px5:   ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC .px6
        ST r1, [r5:r6]
.px6:   ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC .px7
        ST r1, [r5:r6]
.px7:   ADD r6, 1
        JMP .next
.blank: ST r2, [r5:r6]
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
.next:  SUB r6, 8               ; back to the row start, then down a row
        ADD r6, 128
        ADC r5, 0
        ADD rA, 1
        ADC r9, 0
        SUB rB, 1
        JNZ .row
        RET

; 8 bytes a glyph, one bit per pixel, top row first, numbered as FLOOR to HEART say.
glyphs: .byte 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00   ; floor
        .byte 0xFE, 0xFE, 0xFE, 0x00, 0xEF, 0xEF, 0xEF, 0x00   ; wall
        .byte 0x03, 0x03, 0x0F, 0x0F, 0x3F, 0x3F, 0xFF, 0xFF   ; stairs
        .byte 0x18, 0x18, 0x7E, 0x18, 0x18, 0x24, 0x42, 0x00   ; player
        .byte 0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00   ; the digits 0 to 9
        .byte 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00
        .byte 0x3C, 0x66, 0x06, 0x0C, 0x30, 0x60, 0x7E, 0x00
        .byte 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00
        .byte 0x0C, 0x1C, 0x3C, 0x6C, 0x7E, 0x0C, 0x0C, 0x00
        .byte 0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00
        .byte 0x3C, 0x66, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00
        .byte 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00
        .byte 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00
        .byte 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x66, 0x3C, 0x00
        .byte 0x3C, 0x7E, 0xDB, 0xFF, 0xFF, 0x7E, 0x5A, 0x00   ; monster
        .byte 0x6C, 0xFE, 0xFE, 0xFE, 0x7C, 0x38, 0x10, 0x00   ; heart
