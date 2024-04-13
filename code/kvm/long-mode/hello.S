BITS 64

; Output to port 0x3f8
mov dx, 0x3f8

; 0x4000 is added to the message address as that's where our code is loaded
mov rbx, message + 0x4000

loop:
    ; Load a byte from `bx` into the `al` register
    mov al, [rbx]

    ; Jump to the `hlt` instruction if we encountered the NUL terminator
    cmp al, 0
    je end

    ; Output to the serial port
    out dx, al
    ; Increment `rbx` by one byte to point to the next character
    inc rbx

    jmp loop

end:
    hlt

message:
    db "Hello, KVM!", 0
