"""从 JSON 生成 XS01 符号曲谱，不读取 MIDI、不生成 PCM、不访问设备。

每个事件包含 tick 和 25 键的完整状态，tick 单位为 1/96 拍。
首事件必须在 tick=0，末事件 keys 必须为空；相邻事件 tick 严格递增。
"""
import argparse
import json
from pathlib import Path
import struct


def encode(document):
    """检查全部字段后按小端编码，不允许将 bool 当作整数接受。"""
    def integer(value, lower, upper, label):
        if isinstance(value, bool) or not isinstance(value, int) or not lower <= value <= upper:
            raise ValueError(f'{label} must be an integer in{lower}..{upper}')
        return value

    bpm = integer(document.get('bpm', 120), 30, 240, 'bpm')
    base = integer(document.get('base_note', 48), 0, 103, 'base_note')
    events = document.get('events')
    if not isinstance(events, list) or not 2 <= len(events) <= 256:
        raise ValueError('events must contain2..256 complete key states')
    body = bytearray()
    previous = -1
    final_mask = 0
    for index, item in enumerate(events):
        tick = integer(item['tick'], 0, 0xffffffff, f'event{index}.tick')
        if (index == 0 and tick != 0) or tick <= previous:
            raise ValueError('first tick must be0; later ticks must strictly increase')
        keys = item['keys']
        if not isinstance(keys, list):
            raise ValueError('keys must be a list of zero-based key indices')
        mask = 0
        for key in keys:
            key = integer(key, 0, 24, f'event{index}.key')
            if mask & (1 << key):
                raise ValueError('duplicate key index')
            mask |= 1 << key
        body.extend(struct.pack('<Q', tick | mask << 32))
        previous, final_mask = tick, mask
    if final_mask:
        raise ValueError('last event keys must beempty to end the guide')
    return b'XS01' + struct.pack('<HBB', len(events), bpm, base) + body


def demo():
    """返回八和弦练习，每拍切换一次状态，最后释放所有键。"""
    chords = [[0, 4, 7], [2, 5, 9], [4, 7, 11], [5, 9, 12],
              [7, 11, 14], [9, 12, 16], [7, 11, 14, 17], [0, 4, 7, 12], []]
    return {'bpm': 120, 'base_note': 48,
            'events': [{'tick': n * 96, 'keys': chord} for n, chord in enumerate(chords)]}


def main():
    """读取 UTF-8 JSON（可带 BOM），生成指定文件；省略输入则使用演示谱。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, help='JSON with bpm/base_note/events; omit for original8-chord demo')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    document = json.loads(args.input.read_text(encoding='utf-8-sig')) if args.input else demo()
    raw = encode(document)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(raw)
    print(f'Wrote{len(raw)}bytes to{args.output}; symbolic guide only, PPQN96/meter4/4')


if __name__ == '__main__':
    main()
