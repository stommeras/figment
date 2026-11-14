        LDI r1, 64
        LDI r2, 64

frame:  LD r3, [0x3F00]

        MOV r4, r3
        AND r4, 0b0001
        JZ not_up
        SUB r2, 1
not_up:
        MOV r4, r3
        AND r4, 0b0010
        JZ not_down
        ADD r2, 1
not_down:
        MOV r4, r3
        AND r4, 0b0100
        JZ not_left
        SUB r1, 1
not_left:
        MOV r4, r3
        AND r4, 0b1000
        JZ not_right
        ADD r1, 1
not_right:
        AND r1, 0x7F
        AND r2, 0x7F

        LDI r0, 7
        MOV r4, r3
        AND r4, 0b10_0000
        JZ paint
        LD r0, [0x3F02]
        AND r0, 0x0F
paint:  MOV r7, r1
        MOV r8, r2
        CALL plot_r0_at_r7_r8

        LDI r9, 0
        MOV r4, r3
        AND r4, 0b1_0000
        JZ beep
        MOV r9, r1
        SHR r9
        SHR r9
        ADD r9, 48
beep:   ST r9, [0x3F01]

        LDI r0, 0
        LD r7, [0x3F02]
        AND r7, 0x7F
        LD r8, [0x3F02]
        AND r8, 0x7F
        CALL plot_r0_at_r7_r8

        ST r0, [0x3F03]
        JMP frame

plot_r0_at_r7_r8:
        MOV r5, r8
        SHR r5
        ADD r5, 0x40
        MOV r6, r8
        AND r6, 1
        JZ even
        LDI r6, 0x80
even:   OR r6, r7
        ST r0, [r5:r6]
        RET
