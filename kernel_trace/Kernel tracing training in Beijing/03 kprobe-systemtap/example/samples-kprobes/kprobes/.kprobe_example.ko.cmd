cmd_samples/kprobes/kprobe_example.ko := ld -r -m elf_x86_64 -T ./scripts/module-common.lds --build-id  -o samples/kprobes/kprobe_example.ko samples/kprobes/kprobe_example.o samples/kprobes/kprobe_example.mod.o
