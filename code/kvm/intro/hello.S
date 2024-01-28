; Output to port 0x3f8
mov dx, 0x3f8

; Store the address of the message in bx, so we can increment it
mov bx, message

loop:
    ; Load a byte from `bx` into the `al` register
    mov al, [bx]

    ; Jump to the `hlt` instruction if we encountered the NUL terminator
    cmp al, 0
    je end

    ; Output to the serial port
    out dx, al
    ; Increment `bx` by one byte to point to the next character
    inc bx

    jmp loop

end:
    hlt

message:
    db "Hello, KVM!", 0
