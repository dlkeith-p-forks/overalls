import 'package:hegel/hegel.dart';
import 'package:mila_core/mila_core.dart';
import 'package:test/test.dart';

const String _id = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
const String _request = 'porsche-0123456789abcdef0123456789abcdef';

final Generator<MachineShape> _shape = tuple2(
  tuple2(optional(integers(min: 1, max: 64)), optional(integers(min: 1, max: 262144))),
  optional(integers(min: 1, max: maximumDiskGib)),
).map((v) => MachineShape(cpu: v.$1.$1, memoryMib: v.$1.$2, diskGib: v.$2));

void main() {
  test('size fields: blank is absent, canonical positive integers only', () {
    expect(parseSize('', maximum: 10), (valid: true, value: null));
    expect(parseSize(' 4 ', maximum: 10), (valid: true, value: 4));
    for (final bad in ['0', '-1', '04', '1.5', '11', 'x', '+3', '99999999999']) {
      expect(parseSize(bad, maximum: 10).valid, isFalse, reason: bad);
    }
  });

  test('names and sources use the shared grammars', () {
    expect(parseMachineName('dev-box'), (valid: true, value: 'dev-box'));
    expect(parseMachineName(''), (valid: true, value: null));
    expect(parseMachineName('Dev Box').valid, isFalse);
    expect(parseSource('https://github.com/owner/repo').value, 'https://github.com/owner/repo');
    expect(parseSource('https://example.com/owner/repo').valid, isFalse);
  });

  test('new carries only the given values, as a waitless mutation', () {
    final command = createMachineCommand(
      name: 'dev-box',
      shape: const MachineShape(cpu: 2, diskGib: 20),
      requestId: _request,
    )!;
    expect(
      encodeCommand(command),
      'new --cpu=2 --disk=20 --json --name=dev-box --no-wait --request-id=$_request',
    );
    expect(
      createMachineCommand(shape: const MachineShape(diskGib: 501), requestId: _request),
      isNull,
    );
  });

  test('clone names the source machine and an optional new name', () {
    expect(
      encodeCommand(cloneMachineCommand(_id, name: 'copy', requestId: _request)!),
      'clone --json --name=copy --no-wait --request-id=$_request $_id',
    );
    expect(cloneMachineCommand(_id, name: 'Not Valid', requestId: _request), isNull);
  });

  test('resize needs a change and never shrinks the disk', () {
    expect(resizeMachineCommand(_id, const MachineShape(), requestId: _request), isNull);
    expect(
      resizeMachineCommand(
        _id,
        const MachineShape(diskGib: 10),
        currentDiskGib: 20,
        requestId: _request,
      ),
      isNull,
    );
    expect(
      encodeCommand(
        resizeMachineCommand(
          _id,
          const MachineShape(memoryMib: 8192),
          currentDiskGib: 20,
          requestId: _request,
        )!,
      ),
      'resize --json --memory=8192 --no-wait --request-id=$_request $_id',
    );
  });

  property('built commands round-trip through the server grammar', (tc) {
    final shape = tc.draw(_shape, name: 'shape');
    final name = tc.draw(
      optional(fromRegex(r'[a-z][a-z0-9-]{0,20}[a-z0-9]', fullMatch: true)),
      name: 'name',
    );
    final commands = [
      createMachineCommand(name: name, shape: shape, requestId: _request),
      cloneMachineCommand(_id, name: name, requestId: _request),
      resizeMachineCommand(_id, shape, requestId: _request),
    ];
    for (final command in commands.nonNulls) {
      expect(validateCommand(command), isNull);
      expect(parseCommandLine(encodeCommand(command)), command);
      expect(command.options['no-wait'], isTrue);
      expect(command.options['request-id'], _request);
    }
    expect(commands[2] == null, shape.isEmpty);
  });

  property('a typed size parses back to itself or is refused', (tc) {
    final n = tc.draw(integers(min: -5, max: 1000), name: 'n');
    final parsed = parseSize('$n', maximum: 500);
    expect(parsed.valid, n >= 1 && n <= 500);
    if (parsed.valid) expect(parsed.value, n);
  });
}
