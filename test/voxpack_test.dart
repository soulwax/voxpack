import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:voxpack/voxpack.dart';

void main() {
  group('CRC32, RLE codec & VPAK binary archive', () {
    test('builds, parses, verifies CRC32 and detects corruption on tamper', () {
      final repetitive = Uint8List.fromList(List.filled(200, 65)); // compresses via RLE!
      final builder = PakBuilder()
        ..addText('configs/game.json', '{"title":"Volition"}', xorKey: 0x4242)
        ..addBytes('textures/noise.bin', repetitive, compress: true, xorKey: 0x4242);

      final pakBytes = builder.build();
      final pak = PakArchive.parse(pakBytes, xorKey: 0x4242);

      expect(pak.length, 2);
      expect(pak.infoFor('textures/noise.bin')!.isCompressed, isTrue);
      expect(pak.infoFor('textures/noise.bin')!.storedSize, lessThan(200));
      expect(pak.readText('configs/game.json'), '{"title":"Volition"}');
      expect(pak.readBytes('textures/noise.bin'), repetitive);

      // Flip a payload byte -> must trigger CRC32 mismatch!
      final tampered = Uint8List.fromList(pakBytes);
      final info = pak.infoFor('configs/game.json')!;
      tampered[info.dataOffset] ^= 0xFF;
      final pakTampered = PakArchive.parse(tampered, xorKey: 0x4242);
      expect(
        () => pakTampered.readText('configs/game.json'),
        throwsFormatException,
      );
    });
  });

  group('VirtualFileSystem mounts & glob search', () {
    test('resolves highest-priority DLC/mod mount overrides and glob queries', () {
      final basePak = PakBuilder()
        ..addText('scripts/ai.json', '{"mode":"base"}')
        ..addText('levels/intro.lvl', 'L1')
        ..addText('levels/boss.lvl', 'L2');

      final patchMount = MemoryMount(id: 'patch_v1.1', priority: 20)
        ..writeText('scripts/ai.json', '{"mode":"patched"}')
        ..writeText('levels/dlc/arena.lvl', 'DLC');

      final vfs = VirtualFileSystem()
        ..mount(PakMount(id: 'base', archive: PakArchive.parse(basePak.build()), priority: 0))
        ..mount(patchMount);

      expect(vfs.readText('scripts/../scripts/./ai.json'), '{"mode":"patched"}');
      expect(vfs.resolveMountId('scripts/ai.json'), 'patch_v1.1');
      expect(vfs.resolveMountId('levels/intro.lvl'), 'base');

      expect(vfs.list(globPattern: 'levels/**/*.lvl'), [
        'levels/boss.lvl',
        'levels/dlc/arena.lvl',
        'levels/intro.lvl',
      ]);
    });
  });

  group('SaveMigrator ordered schema evolution', () {
    test('upgrades legacy save v1 -> v2 -> v3 without mutating source map', () {
      final migrator = SaveMigrator(targetVersion: 3)
        ..addStep(1, 2, (d) {
          d['hp'] = (d['health'] as num).toInt() * 10;
          d.remove('health');
          return d;
        }, description: 'Convert hearts to numeric HP')
        ..addStep(2, 3, (d) {
          d['inventory'] = {'capacity': 20, 'items': d['items'] ?? []};
          d.remove('items');
          return d;
        }, description: 'Wrap items array into structured inventory');

      final rawV1 = <String, Object?>{
        'schemaVersion': 1,
        'health': 5,
        'items': ['potion'],
      };

      final res = migrator.migrate(rawV1);
      expect(res.didMigrate, isTrue);
      expect(res.fromVersion, 1);
      expect(res.toVersion, 3);
      expect(res.appliedSteps.length, 2);
      expect(res.data['hp'], 50);
      expect((res.data['inventory'] as Map)['capacity'], 20);
      expect(rawV1['schemaVersion'], 1); // original caller map untouched
    });
  });
}
