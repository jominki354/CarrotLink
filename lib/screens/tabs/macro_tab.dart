import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/ssh_service.dart';
import '../../services/macro_service.dart';

class MacroTab extends StatelessWidget {
  const MacroTab({super.key});

  void _showAddDialog(BuildContext context, {int? index, String? initialName, String? initialCmd}) {
    final nameCtrl = TextEditingController(text: initialName);
    final cmdCtrl = TextEditingController(text: initialCmd);
    final isEditing = index != null;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEditing ? "매크로 수정" : "매크로 추가"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "이름")),
            TextField(controller: cmdCtrl, decoration: const InputDecoration(labelText: "명령어")),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("취소")),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.isNotEmpty && cmdCtrl.text.isNotEmpty) {
                final service = Provider.of<MacroService>(context, listen: false);
                if (isEditing) {
                  service.updateMacro(index, nameCtrl.text, cmdCtrl.text);
                } else {
                  service.addMacro(nameCtrl.text, cmdCtrl.text);
                }
                Navigator.pop(ctx);
              }
            },
            child: Text(isEditing ? "수정" : "추가"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final macros = Provider.of<MacroService>(context).macros;

    return Scaffold(
      appBar: AppBar(
        title: const Text("매크로 관리"),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: "기본 매크로 복원",
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text("기본 매크로 복원"),
                  content: const Text("모든 커스텀 매크로가 삭제되고 기본 매크로로 초기화됩니다. 계속하시겠습니까?"),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("취소")),
                    ElevatedButton(
                      onPressed: () {
                        Provider.of<MacroService>(context, listen: false).resetToDefaults();
                        Navigator.pop(ctx);
                      },
                      child: const Text("복원"),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddDialog(context),
        child: const Icon(Icons.add),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 80),
        itemCount: macros.length,
        itemBuilder: (ctx, index) {
          final macro = macros[index];
          return Card(
            child: ListTile(
              title: Text(macro.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(macro.command, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit, color: Colors.blue),
                    onPressed: () => _showAddDialog(context, index: index, initialName: macro.name, initialCmd: macro.command),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => Provider.of<MacroService>(context, listen: false).removeMacro(index),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
