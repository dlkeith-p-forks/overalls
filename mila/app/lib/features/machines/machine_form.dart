// The new, clone and resize forms. Each field is checked with the shared
// grammars before anything is sent; the deployment still decides.
import 'package:flutter/material.dart';
import 'package:mila_core/mila_core.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'machines_controller.dart' show gibibyte;

/// Which form to show.
enum MachineFormKind { create, clone, resize }

/// What a completed form asks for. A null image or team keeps the
/// deployment's default image and a personal machine.
typedef MachineFormResult = ({
  String? name,
  String? source,
  String? image,
  String? team,
  MachineShape shape,
});

/// The images and teams a create form may offer, read while it opens.
typedef MachineChoices = (Future<List<ImageChoice>>, Future<List<TeamChoice>>);

/// Shows the [kind] form; null when cancelled.
Future<MachineFormResult?> showMachineForm(
  BuildContext context,
  MachineFormKind kind, {
  Machine? machine,
  MachineChoices? choices,
}) => showDialog<MachineFormResult>(
  context: context,
  builder: (context) => _MachineFormDialog(kind: kind, machine: machine, choices: choices),
);

class _MachineFormDialog extends StatefulWidget {
  const _MachineFormDialog({required this.kind, this.machine, this.choices});

  final MachineFormKind kind;
  final Machine? machine;
  final MachineChoices? choices;

  @override
  State<_MachineFormDialog> createState() => _MachineFormDialogState();
}

class _MachineFormDialogState extends State<_MachineFormDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _source = TextEditingController();
  final TextEditingController _cpu = TextEditingController();
  final TextEditingController _memory = TextEditingController();
  final TextEditingController _disk = TextEditingController();
  Set<String> _invalid = const {};
  bool _nothing = false;
  List<ImageChoice> _images = const [];
  List<TeamChoice> _teams = const [];
  ImageChoice? _image;
  TeamChoice? _team;

  @override
  void initState() {
    super.initState();
    final choices = widget.choices;
    if (choices == null) return;
    // Either list arriving late or not at all leaves the default in place.
    choices.$1.then((images) {
      if (mounted) setState(() => _images = images);
    }, onError: (Object _) {});
    choices.$2.then((teams) {
      if (mounted) setState(() => _teams = teams);
    }, onError: (Object _) {});
  }

  bool get _named => widget.kind != MachineFormKind.resize;
  bool get _shaped => widget.kind != MachineFormKind.clone;

  @override
  void dispose() {
    for (final c in [_name, _source, _cpu, _memory, _disk]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final name = parseMachineName(_name.text);
    final source = widget.kind == MachineFormKind.create
        ? parseSource(_source.text)
        : (valid: true, value: null);
    final cpu = parseSize(_cpu.text, maximum: maximumShapeValue);
    final memory = parseSize(_memory.text, maximum: maximumShapeValue);
    final disk = parseSize(_disk.text, maximum: maximumDiskGib);
    final invalid = {
      if (!name.valid) 'name',
      if (!source.valid) 'source',
      if (!cpu.valid) 'cpu',
      if (!memory.valid) 'memory',
      if (!disk.valid) 'disk',
    };
    final shape = MachineShape(cpu: cpu.value, memoryMib: memory.value, diskGib: disk.value);
    final currentDisk = widget.machine?.diskBytes;
    final shrinks =
        disk.value != null && currentDisk != null && disk.value! < currentDisk ~/ gibibyte;
    final nothing =
        widget.kind == MachineFormKind.resize && invalid.isEmpty && (shape.isEmpty || shrinks);
    setState(() {
      _invalid = invalid;
      _nothing = nothing;
    });
    if (invalid.isNotEmpty || nothing) return;
    Navigator.of(context).pop((
      name: name.value,
      source: source.value,
      image: _image?.id,
      team: _team?.name,
      shape: shape,
    ));
  }

  Widget _field(
    String key,
    TextEditingController controller,
    String label, {
    String? hint,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: MonoScale.line / 2),
    child: TextField(
      key: Key('machine-form-$key'),
      controller: controller,
      keyboardType: keyboard,
      // Names, URLs and sizes are identifiers: always left to right.
      textDirection: TextDirection.ltr,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: _invalid.contains(key)
            ? MilaLocalizations.of(context).machineFieldInvalid
            : null,
      ),
    ),
  );

  /// A labelled choice among [options], led by the default (null).
  Widget _choice<T extends Object>(
    String key,
    String label,
    List<T> options,
    T? selected,
    String Function(T?) text,
    ValueChanged<T?> onSelected,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: MonoScale.line / 2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        Segmented<T?>(
          keyPrefix: 'machine-form-$key',
          options: [null, ...options],
          selected: selected,
          label: text,
          onSelected: onSelected,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = MilaLocalizations.of(context);
    final machine = widget.machine;
    String? current(int? bytes, int unit) => bytes == null ? null : '${bytes ~/ unit}';
    return AlertDialog(
      title: Text(switch (widget.kind) {
        MachineFormKind.create => l.actionNew,
        MachineFormKind.clone => l.actionClone,
        MachineFormKind.resize => l.actionResize,
      }),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.kind == MachineFormKind.resize)
              Padding(
                padding: const EdgeInsets.only(bottom: MonoScale.line / 2),
                child: Text(l.resizeExplain),
              ),
            if (_named) _field('name', _name, l.machineNameOptional),
            if (widget.kind == MachineFormKind.create)
              _field(
                'source',
                _source,
                l.machineSourceOptional,
                hint: 'https://github.com/owner/repo',
                keyboard: TextInputType.url,
              ),
            if (widget.kind == MachineFormKind.create && _images.isNotEmpty)
              _choice<ImageChoice>(
                'image',
                l.kvImage,
                _images,
                _image,
                (image) => image == null
                    ? l.machineImageDefault
                    : image.architecture == null
                    ? image.name
                    : '${image.name} ${image.architecture}',
                (image) => setState(() => _image = image),
              ),
            if (widget.kind == MachineFormKind.create && _teams.isNotEmpty)
              _choice<TeamChoice>(
                'team',
                l.machineTeam,
                _teams,
                _team,
                (team) => team?.name ?? l.machineTeamPersonal,
                (team) => setState(() => _team = team),
              ),
            if (_shaped) ...[
              _field(
                'cpu',
                _cpu,
                l.kvCpu,
                hint: machine?.vcpu?.toString(),
                keyboard: TextInputType.number,
              ),
              _field(
                'memory',
                _memory,
                l.memoryFieldMib,
                hint: current(machine?.memoryBytes, 1024 * 1024),
                keyboard: TextInputType.number,
              ),
              _field(
                'disk',
                _disk,
                l.diskFieldGib,
                hint: current(machine?.diskBytes, gibibyte),
                keyboard: TextInputType.number,
              ),
            ],
            if (_nothing)
              Text(
                l.resizeNothing,
                key: const Key('machine-form-nothing'),
                style: const TextStyle(fontWeight: MonoScale.bold),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.cancel.toUpperCase()),
        ),
        TextButton(
          key: const Key('machine-form-submit'),
          onPressed: _submit,
          child: Text(
            switch (widget.kind) {
              MachineFormKind.create => l.actionCreate,
              MachineFormKind.clone => l.actionClone,
              MachineFormKind.resize => l.actionResize,
            }.toUpperCase(),
          ),
        ),
      ],
    );
  }
}
