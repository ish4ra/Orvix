from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"Expected patch target not found in {path}: {old[:90]!r}")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")


# Clean the old product name from active user-facing Flutter screens while
# deliberately keeping legacy storage/migration keys untouched for upgrades.
for p in Path("lib/screens").glob("*.dart"):
    text = p.read_text(encoding="utf-8")
    if "Pikora" in text:
        p.write_text(text.replace("Pikora", "Orvix"), encoding="utf-8")

sources_path = "lib/screens/sources_screen.dart"

replace_once(
    sources_path,
    "  final _aioStreamsController = TextEditingController();\n  final _preferredGroupsController = TextEditingController();",
    "  final _aioStreamsController = TextEditingController();\n  final _resultLimitController = TextEditingController();\n  final _preferredGroupsController = TextEditingController();",
)

replace_once(
    sources_path,
    "    _aioStreamsController.dispose();\n    _preferredGroupsController.dispose();",
    "    _aioStreamsController.dispose();\n    _resultLimitController.dispose();\n    _preferredGroupsController.dispose();",
)

replace_once(
    sources_path,
    "      _resultLimit = resultLimit;\n      _preferredGroupsController.text = preferredGroups.join(', ');",
    "      _resultLimit = resultLimit;\n      _resultLimitController.text = resultLimit == 0 ? '' : '$resultLimit';\n      _preferredGroupsController.text = preferredGroups.join(', ');",
)

replace_once(
    sources_path,
    "  Future<void> _setResultLimit(int value) async {\n    setState(() => _resultLimit = value);\n    await widget.sources.setResultLimit(value);\n  }\n",
    "  Future<void> _setResultLimit(int value) async {\n    setState(() => _resultLimit = value);\n    await widget.sources.setResultLimit(value);\n  }\n\n  Future<void> _saveResultLimit() async {\n    final raw = _resultLimitController.text.trim();\n    if (raw.isEmpty) {\n      await _setResultLimit(0);\n      if (!mounted) return;\n      setState(() => _message = 'Source picker will show all ranked results.');\n      return;\n    }\n\n    final value = int.tryParse(raw);\n    if (value == null || value < 1 || value > 500) {\n      setState(() => _message =\n          'Enter any result count from 1 to 500, or leave the field empty for all results.');\n      return;\n    }\n\n    await _setResultLimit(value);\n    if (!mounted) return;\n    setState(() => _message =\n        'Source picker will show the top $value ranked result${value == 1 ? '' : 's'}.');\n  }\n\n  Future<void> _showAllResults() async {\n    _resultLimitController.clear();\n    await _setResultLimit(0);\n    if (!mounted) return;\n    setState(() => _message = 'Source picker will show all ranked results.');\n  }\n",
)

old_ui = """          Row(\n            crossAxisAlignment: CrossAxisAlignment.center,\n            children: [\n              Expanded(\n                child: Column(\n                  crossAxisAlignment: CrossAxisAlignment.start,\n                  children: [\n                    const Text(\n                      'Results shown in source picker',\n                      style: TextStyle(fontWeight: FontWeight.w800),\n                    ),\n                    const SizedBox(height: 4),\n                    Text(\n                      'Choose how many ranked sources are displayed when you open the source picker.',\n                      style: TextStyle(\n                        color: color.onSurfaceVariant,\n                        height: 1.35,\n                      ),\n                    ),\n                  ],\n                ),\n              ),\n              const SizedBox(width: 18),\n              DropdownButton<int>(\n                value: _resultLimit,\n                borderRadius: BorderRadius.circular(12),\n                items: [\n                  for (final value in SourceProviderService.resultLimitOptions)\n                    DropdownMenuItem<int>(\n                      value: value,\n                      child: Text(value == 0 ? 'All results' : 'Top $value'),\n                    ),\n                ],\n                onChanged: _busy\n                    ? null\n                    : (value) {\n                        if (value != null) _setResultLimit(value);\n                      },\n              ),\n            ],\n          ),\n"""

new_ui = """          Column(\n            crossAxisAlignment: CrossAxisAlignment.start,\n            children: [\n              const Text(\n                'Results shown in source picker',\n                style: TextStyle(fontWeight: FontWeight.w800),\n              ),\n              const SizedBox(height: 4),\n              Text(\n                'Choose any result count you want. Enter 1 for one result, 3 for three results, or leave it empty to show everything.',\n                style: TextStyle(\n                  color: color.onSurfaceVariant,\n                  height: 1.35,\n                ),\n              ),\n              const SizedBox(height: 12),\n              Wrap(\n                spacing: 10,\n                runSpacing: 10,\n                crossAxisAlignment: WrapCrossAlignment.center,\n                children: [\n                  SizedBox(\n                    width: 190,\n                    child: TextField(\n                      controller: _resultLimitController,\n                      enabled: !_busy,\n                      keyboardType: TextInputType.number,\n                      onSubmitted: (_) => _busy ? null : _saveResultLimit(),\n                      decoration: InputDecoration(\n                        labelText: _resultLimit == 0\n                            ? 'All results'\n                            : 'Top $_resultLimit',\n                        hintText: 'e.g. 3',\n                        prefixIcon: const Icon(Icons.numbers_rounded),\n                      ),\n                    ),\n                  ),\n                  FilledButton.icon(\n                    onPressed: _busy ? null : _saveResultLimit,\n                    icon: const Icon(Icons.check_rounded),\n                    label: const Text('Apply'),\n                  ),\n                  TextButton(\n                    onPressed: _busy ? null : _showAllResults,\n                    child: const Text('All results'),\n                  ),\n                ],\n              ),\n            ],\n          ),\n"""
replace_once(sources_path, old_ui, new_ui)

# The old preset list is intentionally gone: result limits are now arbitrary.
service = Path("lib/services/source_provider_service.dart")
text = service.read_text(encoding="utf-8")
text = text.replace("  static const resultLimitOptions = <int>[25, 50, 100, 200, 0];\n", "")
service.write_text(text, encoding="utf-8")
