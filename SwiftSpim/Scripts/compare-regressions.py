#!/usr/bin/env python3
"""Compare focused review regressions with the original r764 terminal oracle."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reference', default=os.environ.get('SPIM_REFERENCE'))
parser.add_argument('--exceptions', default=os.environ.get('SPIM_EXCEPTION_FILE'))
parser.add_argument('--binary', default=str(root / '.build/debug/swiftspim-cli'))
args = parser.parse_args()
if not args.reference or not args.exceptions:
    parser.error('set SPIM_REFERENCE and SPIM_EXCEPTION_FILE, or supply both options')
reference = str(Path(args.reference).resolve())
binary = str(Path(args.binary).resolve())
handler = str(Path(args.exceptions).resolve())


def program(body, data=''):
    return ('.data\n' + data + '\n.text\n.globl __start\n.globl main\n__start:\nmain: ' + body).encode()


exit_code = 'li $v0,10\nsyscall\n'
print_result = 'move $a0,$v0\nli $v0,1\nsyscall\n' + exit_code
cases = [
    ('unknown-syscall', program('li $v0,99\nsyscall\n'), b'', ['-noexception']),
    ('missing-instruction', program('addu $0,$0,$0\n'), b'', ['-noexception']),
    ('undefined-jump', program('j absent\n'), b'', ['-noexception']),
    ('overflow-no-handler', program('li $t0,0x7fffffff\naddi $t0,$t0,1\n'), b'', ['-noexception']),
    ('missing-start', b'.text\n.globl main\nmain: li $v0,10\nsyscall\n', b'', ['-noexception']),
    ('exit-status', program('li $v0,17\nli $a0,7\nsyscall\n'), b'', ['-noexception']),
    ('sbrk-negative', program('li $a0,-4\nli $v0,9\nsyscall\n'), b'', ['-noexception']),
    ('sbrk-limit', program('li $a0,4194304\nli $v0,9\nsyscall\n'), b'', ['-noexception']),
    ('raw-char-output', program('li $a0,255\nli $v0,11\nsyscall\n' + exit_code), b'', ['-noexception']),
    ('split-utf8-output', program('li $a0,195\nli $v0,11\nsyscall\nli $a0,169\nli $v0,11\nsyscall\n' + exit_code), b'', ['-noexception']),
    ('raw-char-input', program('li $v0,12\nsyscall\n' + print_result), b'\xe9', ['-noexception']),
    ('eof-char', program('li $v0,12\nsyscall\n' + print_result), b'', ['-noexception']),
    ('eof-string', program('la $a0,buf\nli $a1,4\nli $v0,8\nsyscall\nlbu $a0,buf\nli $v0,1\nsyscall\n' + exit_code, 'buf: .byte 85, 85, 85, 85'), b'', ['-noexception']),
    ('eof-read', program('li $a0,0\nla $a1,buf\nli $a2,4\nli $v0,14\nsyscall\n' + print_result, 'buf: .space 4'), b'', ['-noexception']),
    ('raw-string-input', program('la $a0,buf\nli $a1,4\nli $v0,8\nsyscall\nla $a0,buf\nli $v0,4\nsyscall\n' + exit_code, 'buf: .space 4'), b'\xe9\n', ['-noexception']),
    ('raw-source-literal', program('la $a0,msg\nli $v0,4\nsyscall\n' + exit_code, 'msg: .asciiz "RAW_BYTE"').replace(b'RAW_BYTE', b'\xe9') + b'# Latin-1 comment \xe9\n', b'', ['-noexception']),
    ('duplicate-label', b'.data\nx: .word 1\nx: .word 2\n' + program('li $a0,42\nli $v0,1\nsyscall\n' + exit_code), b'', ['-noexception']),
    ('ignored-rev2', b'.text\nseb $t0,$t1\n' + program(exit_code), b'', ['-noexception']),
    ('divide-by-zero-constant', b'.text\ndiv $t0,$t1,0\n' + program(exit_code), b'', ['-noexception']),
    ('data-in-text', b'.text\n.asciiz "x"\n' + program(exit_code), b'', ['-noexception']),
    ('assembler-warnings', b'.text\naddu $1,$2,$3\n.repeat 3\n.struct 4\n' + program(exit_code), b'', ['-noexception']),
]
cases.extend([
    ('nul-char-input', program('li $v0,12\nsyscall\n' + print_result), b'\0', ['-noexception']),
    ('closed-stdin', program('li $a0,0\nli $v0,16\nsyscall\nli $a0,0\nla $a1,buf\nli $a2,1\nli $v0,14\nsyscall\n' + print_result, 'buf: .space 4'), b'', ['-noexception']),
    ('binary-stderr', program('li $a0,2\nla $a1,buf\nli $a2,1\nli $v0,15\nsyscall\n' + print_result, 'buf: .byte 255'), b'', ['-noexception']),
    ('disabled-custom-handler', program(exit_code), b'', ['-ef', handler, '-noexception']),
    ('bare-default-handler', b'.text\n.globl main\nmain: ori $v0,$0,10\nsyscall\n', b'', ['-bare', '-ef', handler]),
])
stack_body = 'move $s0,$a0\nmove $s1,$a1\nmove $s2,$a2\nmove $s3,$sp\n'
for register in ('$s0','$s1','$s2','$s3'):
    stack_body += f'move $a0,{register}\nli $v0,1\nsyscall\nli $a0,32\nli $v0,11\nsyscall\n'
stack_body += 'lw $a0,0($s1)\nli $v0,4\nsyscall\nli $a0,32\nli $v0,11\nsyscall\nlw $a0,0($s2)\nli $v0,4\nsyscall\n' + exit_code
cases.append(('stack-abi-environment', program(stack_body), b'', ['-noexception']))
# Same source path and a small explicit environment on both sides. Never dump
# the developer's inherited environment into comparison logs. Explicit CF
# and Swift runtime entries keep both processes' effective vectors identical.
failed = 0
with tempfile.TemporaryDirectory(prefix='swiftspim-regressions-') as directory:
    for name, source, standard_input, flags in cases:
        source_file = Path(directory) / (name + '.s')
        source_file.write_bytes(source)
        results = []
        for executable in (reference, binary):
            results.append(subprocess.run([executable, *flags, '-file', str(source_file)],
                input=standard_input, capture_output=True, env={'TEST': 'fixture', '_CF_USER_TEXT_ENCODING': '0x1F5:0x0:0x0', '__CF_USER_TEXT_ENCODING': '0x1F5:0x0:0x0', 'SWIFT_BACKTRACE': 'enable=no,interactive=no'}, timeout=15))
        a, b = results
        if (a.returncode, a.stdout, a.stderr) == (b.returncode, b.stdout, b.stderr):
            print('PASS', name)
        else:
            failed += 1
            print('DIFF', name)
            for label, result in zip(('reference', 'Swift'), results):
                print(label, 'status:', result.returncode, 'stdout:', repr(result.stdout), 'stderr:', repr(result.stderr))
    # A nonquiet exception run supplements the quiet full-fixture comparison.
    source_file = Path(directory) / 'nonquiet.s'
    source_file.write_text('.text\n.globl main\nmain: li $t0,0x7fffffff\naddi $t0,$t0,1\nli $v0,10\nsyscall\n')
    for quiet in (False, True):
        flags = ['-quiet'] if quiet else []
        results = [subprocess.run([executable, *flags, '-ef', handler, '-file', str(source_file)], input=b'', capture_output=True, env={'TEST': 'fixture', '_CF_USER_TEXT_ENCODING': '0x1F5:0x0:0x0', '__CF_USER_TEXT_ENCODING': '0x1F5:0x0:0x0', 'SWIFT_BACKTRACE': 'enable=no,interactive=no'}, timeout=15) for executable in (reference, binary)]
        a, b = results
        name = 'exception-quiet' if quiet else 'exception-nonquiet'
        if (a.returncode,a.stdout,a.stderr) == (b.returncode,b.stdout,b.stderr): print('PASS', name)
        else:
            failed += 1
            print('DIFF',name,repr(a.stdout),repr(b.stdout),repr(a.stderr),repr(b.stderr))
print(f'{len(cases) + 2 - failed}/{len(cases) + 2} regression comparisons matched')
raise SystemExit(bool(failed))
