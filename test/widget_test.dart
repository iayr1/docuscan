import 'package:flutter_test/flutter_test.dart';
import 'package:docu_scan/main.dart';
void main(){testWidgets('DocuScan home renders',(tester)async{await tester.pumpWidget(const DocuScan());expect(find.text('Everything in'),findsOneWidget);expect(find.text('Recent documents'),findsOneWidget);});}
