import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/romm/romm_models.dart';
import 'package:freegosy/core/storage/directory_service.dart';
import 'package:freegosy/core/storage/file_system_index.dart';
import 'package:freegosy/providers/romm_provider.dart';
import 'package:freegosy/providers/retroachievements_provider.dart';
import 'package:freegosy/providers/shared_prefs_provider.dart';
import 'package:freegosy/ui/screens/settings_screen.dart';
import 'package:freegosy/core/romm/romm_service.dart';
import 'package:freegosy/core/emulator/strategy_registry.dart';
import 'package:freegosy/core/emulator/emulator_strategy.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:freegosy/core/input/input_action_bus.dart';
import 'package:freegosy/core/input/gamepad_service.dart';

import 'settings_screen_test.mocks.dart';

@GenerateMocks([DirectoryService, RommService, StrategyRegistry])
void main() {
  late MockDirectoryService mockDirectoryService;
  late MockRommService mockRommService;
  late MockStrategyRegistry mockStrategyRegistry;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'rommBaseUrl': 'https://old.com',
      'rommUsername': 'olduser',
    });
    prefs = await SharedPreferences.getInstance();
    mockDirectoryService = MockDirectoryService();
    mockRommService = MockRommService();
    mockStrategyRegistry = MockStrategyRegistry();
    
    when(mockDirectoryService.romsRootPath).thenReturn('/roms');
    when(mockDirectoryService.emulatorsRootPath).thenReturn('/emulators');
    when(mockDirectoryService.status).thenReturn(const StorageStatus());
    when(mockDirectoryService.isEmulatorInstalled(any, any)).thenAnswer((_) async => true);
    when(mockDirectoryService.getEmulatorPathOverride(any)).thenReturn(null);
    when(mockDirectoryService.linuxSyncPreset).thenReturn('default');
    when(mockDirectoryService.useFlatEmulatorLayout).thenReturn(false);
    when(mockRommService.getPlatforms()).thenAnswer((_) async => []);
    when(mockStrategyRegistry.detectConflicts()).thenReturn(<String, ({List<EmulatorStrategy> strategies, List<String> mergedSlugs})>{});
    when(mockStrategyRegistry.coreOverrides).thenReturn(<String, String>{});
    when(mockStrategyRegistry.getStrategyById(any)).thenReturn(null);
  });

  Widget createSettingsScreen({void Function()? onRommServiceCreated}) {
    return ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        rommServiceProvider.overrideWith((ref) {
          ref.watch(rommConfigProvider);
          onRommServiceCreated?.call();
          return mockRommService;
        }),
        directoryServiceProvider.overrideWith((ref) => Future.value(mockDirectoryService)),
        strategyRegistryProvider.overrideWith((ref) => Future.value(mockStrategyRegistry)),
        rommConfigProvider.overrideWith((ref) => Future.value(RomMConfig(
          baseUrl: 'https://old.com',
          username: 'olduser',
          password: 'oldpassword',
        ))),
        // Avoid hitting SecureStorageService/the network for an unrelated
        // section — no RetroAchievements account is connected in these tests.
        retroAchievementsCredentialsProvider.overrideWith((ref) => Future.value(null)),
      ],
      child: const MaterialApp(
        home: SettingsScreen(),
      ),
    );
  }

  group('SettingsScreen', () {
    testWidgets('saving the slot keeps the existing RomM connection', (tester) async {
      var serviceCreations = 0;
      await tester.pumpWidget(createSettingsScreen(
        onRommServiceCreated: () => serviceCreations++,
      ));
      await tester.pumpAndSettle();
      final initialCreations = serviceCreations;
      expect(initialCreations, greaterThan(0));
      final field = find.byKey(const ValueKey('rommSaveSlot'));
      await tester.ensureVisible(field);
      await tester.enterText(field, 'autosave');
      final save = find.text('Save slot');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(serviceCreations, initialCreations);
      expect(prefs.getString(RomMConfig.saveSlotPreferenceKey), 'autosave');
    });

    testWidgets('rejects an overlong RomM slot without changing the setting', (tester) async {
      await prefs.setString(RomMConfig.saveSlotPreferenceKey, 'autosave');
      await tester.pumpWidget(createSettingsScreen());
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('rommSaveSlot'));
      final save = find.text('Save slot');
      await tester.ensureVisible(field);
      await tester.enterText(field, 'x' * 256);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('Use 255 characters or fewer.'), findsOneWidget);
      expect(prefs.getString(RomMConfig.saveSlotPreferenceKey), 'autosave');
      expect(find.text('RomM save slot saved.'), findsNothing);

      await tester.ensureVisible(field);
      await tester.enterText(field, 'custom');
      await tester.pump();
      expect(find.text('Use 255 characters or fewer.'), findsNothing);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(prefs.getString(RomMConfig.saveSlotPreferenceKey), 'custom');
    });

    testWidgets('RomM save slot defaults to freegosy and persists autosave across reopen', (tester) async {
      await tester.pumpWidget(createSettingsScreen());
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('rommSaveSlot'));
      await tester.ensureVisible(field);
      expect(tester.widget<TextField>(field).controller!.text, 'freegosy');

      await tester.enterText(field, ' autosave ');
      final save = find.text('Save slot');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(prefs.getString(RomMConfig.saveSlotPreferenceKey), 'autosave');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(createSettingsScreen());
      await tester.pumpAndSettle();
      await tester.ensureVisible(field);
      expect(tester.widget<TextField>(field).controller!.text, 'autosave');
    });

    testWidgets('RomM save slot accepts custom names and resets blank to the default', (tester) async {
      await tester.pumpWidget(createSettingsScreen());
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('rommSaveSlot'));
      final save = find.text('Save slot');

      for (final value in ['My playthrough', ' ']) {
        await tester.ensureVisible(field);
        await tester.enterText(field, value);
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        final expected = value.trim().isEmpty ? 'freegosy' : value;
        expect(prefs.getString(RomMConfig.saveSlotPreferenceKey), expected);
        expect(tester.widget<TextField>(field).controller!.text, expected);
      }
    });

    testWidgets('renders server configuration fields', (WidgetTester tester) async {
      await tester.pumpWidget(createSettingsScreen());
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsWidgets);
      expect(find.text('Server URL'), findsWidgets);
    });

    testWidgets('renders storage section', (WidgetTester tester) async {
      // Set large surface size to avoid ListView lazy loading issues
      tester.view.physicalSize = const Size(1200, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(createSettingsScreen());
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.textContaining('/roms'), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('roms'), findsWidgets);
      await tester.scrollUntilVisible(find.textContaining('/emulators'), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('emulators'), findsWidgets);
    });

    testWidgets('renders emulator section', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(createSettingsScreen());
      await tester.pumpAndSettle();

      // Scroll to the bottom of the settings list to find the Emulators section
      final listView = find.byType(ListView).first;
      await tester.drag(listView, const Offset(0, -2000));
      expect(find.text('Emulators'), findsWidgets);
    });

    testWidgets('custom combo selectors and toggles interact perfectly without crashing', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(createSettingsScreen());
      await tester.pumpAndSettle();

      // Find the Active Theme combo box card
      final activeThemeButton = find.text('Active Theme');
      expect(activeThemeButton, findsOneWidget);

      // Tap on it to open the dialog
      await tester.tap(activeThemeButton);
      await tester.pumpAndSettle();

      // Check that the dialog is open by looking for 'Select Active Theme'
      expect(find.text('Select Active Theme'), findsOneWidget);

      // Verify the dialog contains different theme choices
      expect(find.text('Light Mode'), findsOneWidget);
      expect(find.text('Rose Gold'), findsOneWidget);

      // Tap on 'Rose Gold' to select it
      await tester.tap(find.text('Rose Gold'));
      await tester.pumpAndSettle();

      // Verify the dialog is dismissed
      expect(find.text('Select Active Theme'), findsNothing);

      // Find the Show game title toggle card and tap it
      final toggleText = find.text('Show game title');
      expect(toggleText, findsOneWidget);
      await tester.ensureVisible(toggleText);
      await tester.pumpAndSettle();
      await tester.tap(toggleText);
      await tester.pumpAndSettle();
      expect(prefs.getBool('show_title'), isFalse);
    });

    testWidgets('combo selector dialog can be dismissed using GameAction.back', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(createSettingsScreen());
      await tester.pumpAndSettle();

      // Find the Active Theme combo box card
      final activeThemeButton = find.text('Active Theme');
      expect(activeThemeButton, findsOneWidget);

      // Tap on it to open the dialog
      await tester.tap(activeThemeButton);
      await tester.pumpAndSettle();

      // Check that the dialog is open by looking for 'Select Active Theme'
      expect(find.text('Select Active Theme'), findsOneWidget);

      // Trigger GameAction.back via the bus
      inputActionBus.add(GameAction.back);
      await tester.pumpAndSettle();

      // Verify the dialog is dismissed
      expect(find.text('Select Active Theme'), findsNothing);
    });
  });
}
