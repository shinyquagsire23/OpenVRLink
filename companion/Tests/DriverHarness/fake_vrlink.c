// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Mock `driver_vrlink.dll` for end-to-end driver testing. Exports wrappers around
// functions whose prologues match the byte signatures in `Scan` (`PatchCore`),
// increments call counters, and imports `D3DReadFileToBlob` like the real
// `driver_vrlink.dll`.

int parse_calls = 0, populate_calls = 0;

__asm__(
    ".text\n"
    ".globl fake_parse\n"
    "fake_parse:\n"
    "  .byte 0x45,0x85,0xC0\n"                      // test r8d, r8d
    "  .byte 0x0F,0x8E\n"                           // jle parse_done
    "  .long parse_done - 1f\n"
    "1:\n"
    "  .byte 0x48,0x8B,0xC4\n"                      // mov rax, rsp
    "  .byte 0x48,0x89,0x50,0x10\n"                 // mov [rax+10h], rdx
    "  .byte 0x48,0x89,0x48,0x08\n"                 // mov [rax+8], rcx
    "  .byte 0x55,0x53,0x41,0x54\n"                 // push rbp / rbx / r12
    "  .byte 0x48,0x8D,0x68,0xA1\n"                 // lea rbp, [rax-5Fh]
    "  .byte 0x48,0x81,0xEC,0xB0,0x00,0x00,0x00\n"  // sub rsp, 0B0h
    "  .byte 0x48,0x89,0x70,0xE0\n"                 // mov [rax-20h], rsi
    "  .byte 0x4C,0x8B,0xE1\n"                      // mov r12, rcx
    "  incl parse_calls(%rip)\n"
    "  movq 0xA8(%rsp), %rsi\n"
    "  addq $0xB0, %rsp\n"
    "  popq %r12\n"
    "  popq %rbx\n"
    "  popq %rbp\n"
    "parse_done:\n"
    "  ret\n"
    ".globl fake_populate\n"
    "fake_populate:\n"
    "  .byte 0x48,0x89,0x54,0x24,0x10\n"            // mov [rsp+10h], rdx
    "  .byte 0x48,0x89,0x4C,0x24,0x08\n"            // mov [rsp+8], rcx
    "  .byte 0x55,0x53,0x56,0x57\n"                 // push rbp / rbx / rsi / rdi
    "  .byte 0x41,0x54,0x41,0x55,0x41,0x56,0x41,0x57\n" // push r12..r15
    "  .byte 0x48,0x8D,0x6C,0x24,0xE1\n"            // lea rbp, [rsp-1Fh]
    "  .byte 0x48,0x81,0xEC,0x88,0x00,0x00,0x00\n"  // sub rsp, 88h
    "  .byte 0x33,0xF6\n"                           // xor esi, esi
    "  .byte 0x49,0x63,0xC0\n"                      // movsxd rax, r8d
    "  .byte 0x48,0x89,0x45,0xEF\n"                 // mov [rbp-11h], rax
    "  .byte 0x8B,0xDE\n"                           // mov ebx, esi
    "  incl populate_calls(%rip)\n"
    "  addq $0x88, %rsp\n"
    "  popq %r15\n"
    "  popq %r14\n"
    "  popq %r13\n"
    "  popq %r12\n"
    "  popq %rdi\n"
    "  popq %rsi\n"
    "  popq %rbx\n"
    "  popq %rbp\n"
    "  ret\n");

// The start of the Direct3D constants function, then a return that undoes it.
__asm__(
    ".text\n"
    ".globl fake_constants\n"
    "fake_constants:\n"
    "  .byte 0x48,0x89,0x5C,0x24,0x08\n"            // mov [rsp+8], rbx
    "  .byte 0x48,0x89,0x6C,0x24,0x10\n"            // mov [rsp+10h], rbp
    "  .byte 0x48,0x89,0x74,0x24,0x18\n"            // mov [rsp+18h], rsi
    "  .byte 0x57\n"                                // push rdi
    "  .byte 0x48,0x81,0xEC,0xA0,0x00,0x00,0x00\n"  // sub rsp, 0A0h
    "  .byte 0x0F,0xB6,0xFA\n"                      // movzx edi, dl
    "  .byte 0x41,0x8B,0xE9\n"                      // mov ebp, r9d
    "  .byte 0x33,0xD2\n"                           // xor edx, edx
    "  .byte 0x41,0x0F,0xB6,0xF0\n"                 // movzx esi, r8b
    "  .byte 0x48,0x8B,0xD9\n"                      // mov rbx, rcx
    "  .byte 0x48,0x8D,0x4C,0x24,0x30\n"            // lea rcx, [rsp+30h]
    "  .byte 0x44,0x8D,0x42,0x70\n"                 // lea r8d, [rdx+70h]
    "  movq 0xD8(%rsp), %rax\n"                     // the sixth argument: the constants
    "  cvtsi2ss %ebp, %xmm0\n"
    "  movss %xmm0, 0x20(%rax)\n"                   // width, where the real function puts it
    "  movq 0xB0(%rsp), %rbx\n"
    "  movq 0xB8(%rsp), %rbp\n"
    "  movq 0xC0(%rsp), %rsi\n"
    "  addq $0xA0, %rsp\n"
    "  popq %rdi\n"
    "  ret\n");

extern void fake_constants(void *driver, char layer, char flag, unsigned width, unsigned height, float *constants);

__declspec(dllexport) float call_constants(float *constants) {
    fake_constants(0, 1, 0, 1536, 1024, constants);
    return constants[8];
}

extern unsigned long long fake_parse(void *root, const void *records, int count);
extern unsigned long long fake_populate(void *root, void *records, int count);

// The real driver reads each Direct3D shader with this import.
extern long __stdcall D3DReadFileToBlob(const unsigned short *path, void **blob);

// Returns the size of the shader read, or the failure code, and releases it as the driver does.
__declspec(dllexport) long call_read_shader(const unsigned short *path, unsigned char *first_bytes) {
    void ***blob = 0;
    long result = D3DReadFileToBlob(path, (void **)&blob);
    if (result < 0) return result;
    unsigned char *bytes = ((unsigned char *(__stdcall *)(void *))(*blob)[3])(blob);
    long size = (long)((unsigned long long (__stdcall *)(void *))(*blob)[4])(blob);
    for (int i = 0; i < 4; i++) first_bytes[i] = bytes[i];
    ((unsigned long (__stdcall *)(void *))(*blob)[2])(blob);
    return size;
}

__declspec(dllexport) int call_parse(void *root, const void *records, int count) {
    fake_parse(root, records, count);
    return parse_calls;
}

__declspec(dllexport) int call_populate(void *root, void *records, int count) {
    fake_populate(root, records, count);
    return populate_calls;
}
