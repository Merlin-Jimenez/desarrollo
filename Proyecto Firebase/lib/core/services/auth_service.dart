// auth_service.dart
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  // Stream del usuario actual
  Stream<User?> get authStateChanges => _auth.authStateChanges();
  
  User? get currentUser => _auth.currentUser;

  // Registro con email
  Future<UserCredential> registrarConEmail({
    required String email,
    required String password,
    required String nombre,
    required String rol,
    String? telefono,
  }) async {
    try {
      final userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Crear documento de usuario
      await _firestore.collection('usuarios').doc(userCredential.user!.uid).set({
        'nombre': nombre,
        'email': email,
        'telefono': telefono,
        'rol': rol,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Si es doctor, crear documento adicional
      if (rol == 'doctor') {
        await _firestore.collection('doctores').doc(userCredential.user!.uid).set({
          'usuarioId': userCredential.user!.uid,
          'especialidad': '',
          'clinicasIds': [],
          'horarioSemanal': {},
          'activo': true,
        });
      }

      return userCredential;
    } catch (e) {
      rethrow;
    }
  }

  // Login con email
  Future<UserCredential> loginConEmail({
    required String email,
    required String password,
  }) async {
    try {
      return await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
    } catch (e) {
      rethrow;
    }
  }

  // Login con Google
  Future<UserCredential?> loginConGoogle() async {
    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      
      if (googleUser == null) return null;

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final userCredential = await _auth.signInWithCredential(credential);

      // Verificar si el usuario ya existe
      final userDoc = await _firestore
          .collection('usuarios')
          .doc(userCredential.user!.uid)
          .get();

      if (!userDoc.exists) {
        // Crear nuevo usuario
        await _firestore.collection('usuarios').doc(userCredential.user!.uid).set({
          'nombre': googleUser.displayName ?? '',
          'email': googleUser.email,
          'rol': 'paciente',
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      return userCredential;
    } catch (e) {
      rethrow;
    }
  }

  // Cerrar sesión
  Future<void> cerrarSesion() async {
    await _googleSignIn.signOut();
    await _auth.signOut();
  }

  // Obtener rol del usuario
  Future<String> obtenerRolUsuario(String uid) async {
    final doc = await _firestore.collection('usuarios').doc(uid).get();
    return doc.data()?['rol'] ?? 'paciente';
  }

  // Actualizar FCM Token
  Future<void> actualizarFCMToken(String token) async {
    final uid = currentUser?.uid;
    if (uid != null) {
      await _firestore.collection('usuarios').doc(uid).update({
        'fcmToken': token,
      });
    }
  }
}

// citas_repository.dart
class CitasRepository {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Obtener disponibilidad de un doctor en una fecha
  Future<List<DateTime>> obtenerHorariosDisponibles({
    required String doctorId,
    required String clinicaId,
    required DateTime fecha,
  }) async {
    try {
      // Obtener horario del doctor
      final doctorDoc = await _firestore.collection('doctores').doc(doctorId).get();
      final doctorData = doctorDoc.data();
      
      if (doctorData == null) return [];

      final diaSemana = _obtenerDiaSemana(fecha.weekday);
      final horarioSemanal = doctorData['horarioSemanal'] as Map<String, dynamic>?;
      
      if (horarioSemanal == null || !horarioSemanal.containsKey(diaSemana)) {
        return [];
      }

      final horarioDia = horarioSemanal[diaSemana] as Map<String, dynamic>;
      
      if (horarioDia['clinicaId'] != clinicaId || horarioDia['disponible'] == false) {
        return [];
      }

      // Generar slots de tiempo
      final horaInicio = _parsearHora(horarioDia['horaInicio']);
      final horaFin = _parsearHora(horarioDia['horaFin']);
      final duracion = horarioDia['duracionConsultaMinutos'] as int? ?? 30;

      final slots = <DateTime>[];
      var horaActual = DateTime(fecha.year, fecha.month, fecha.day, horaInicio.hour, horaInicio.minute);
      final horaLimite = DateTime(fecha.year, fecha.month, fecha.day, horaFin.hour, horaFin.minute);

      while (horaActual.isBefore(horaLimite)) {
        slots.add(horaActual);
        horaActual = horaActual.add(Duration(minutes: duracion));
      }

      // Obtener citas existentes
      final citasSnapshot = await _firestore
          .collection('citas')
          .where('doctorId', isEqualTo: doctorId)
          .where('fecha', isGreaterThanOrEqualTo: Timestamp.fromDate(
            DateTime(fecha.year, fecha.month, fecha.day, 0, 0)))
          .where('fecha', isLessThan: Timestamp.fromDate(
            DateTime(fecha.year, fecha.month, fecha.day, 23, 59)))
          .get();

      final citasOcupadas = citasSnapshot.docs
          .where((doc) => doc.data()['estado'] != 'cancelada')
          .map((doc) => (doc.data()['fecha'] as Timestamp).toDate())
          .toList();

      // Filtrar slots disponibles
      return slots.where((slot) {
        return !citasOcupadas.any((cita) =>
            cita.isAtSameMomentAs(slot) ||
            (cita.isBefore(slot.add(Duration(minutes: duracion))) &&
                cita.isAfter(slot.subtract(Duration(minutes: duracion)))));
      }).toList();
    } catch (e) {
      rethrow;
    }
  }

  // Crear nueva cita
  Future<String> crearCita({
    required String pacienteId,
    required String doctorId,
    required String clinicaId,
    required DateTime fecha,
    int duracionMinutos = 30,
    String? notas,
  }) async {
    try {
      // Verificar disponibilidad
      final disponible = await verificarDisponibilidad(
        doctorId: doctorId,
        fecha: fecha,
        duracionMinutos: duracionMinutos,
      );

      if (!disponible) {
        throw Exception('El horario seleccionado ya no está disponible');
      }

      final citaRef = await _firestore.collection('citas').add({
        'pacienteId': pacienteId,
        'doctorId': doctorId,
        'clinicaId': clinicaId,
        'fecha': Timestamp.fromDate(fecha),
        'duracionMinutos': duracionMinutos,
        'estado': 'pendiente',
        'notas': notas,
        'createdAt': FieldValue.serverTimestamp(),
      });

      return citaRef.id;
    } catch (e) {
      rethrow;
    }
  }

  // Verificar disponibilidad
  Future<bool> verificarDisponibilidad({
    required String doctorId,
    required DateTime fecha,
    required int duracionMinutos,
  }) async {
    final inicio = fecha;
    final fin = fecha.add(Duration(minutes: duracionMinutos));

    final citasSnapshot = await _firestore
        .collection('citas')
        .where('doctorId', isEqualTo: doctorId)
        .where('fecha', isGreaterThanOrEqualTo: Timestamp.fromDate(
          inicio.subtract(Duration(minutes: duracionMinutos))))
        .where('fecha', isLessThan: Timestamp.fromDate(fin))
        .get();

    final citasActivas = citasSnapshot.docs
        .where((doc) => doc.data()['estado'] != 'cancelada')
        .toList();

    return citasActivas.isEmpty;
  }

  // Actualizar estado de cita
  Future<void> actualizarEstadoCita(String citaId, String nuevoEstado) async {
    await _firestore.collection('citas').doc(citaId).update({
      'estado': nuevoEstado,
    });
  }

  // Obtener citas de un paciente
  Stream<List<Cita>> obtenerCitasPaciente(String pacienteId) {
    return _firestore
        .collection('citas')
        .where('pacienteId', isEqualTo: pacienteId)
        .orderBy('fecha', descending: true)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Cita.fromFirestore(doc)).toList());
  }

  // Obtener citas de un doctor
  Stream<List<Cita>> obtenerCitasDoctor(String doctorId, DateTime fecha) {
    final inicioDia = DateTime(fecha.year, fecha.month, fecha.day, 0, 0);
    final finDia = DateTime(fecha.year, fecha.month, fecha.day, 23, 59);

    return _firestore
        .collection('citas')
        .where('doctorId', isEqualTo: doctorId)
        .where('fecha', isGreaterThanOrEqualTo: Timestamp.fromDate(inicioDia))
        .where('fecha', isLessThanOrEqualTo: Timestamp.fromDate(finDia))
        .orderBy('fecha')
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => Cita.fromFirestore(doc)).toList());
  }

  // Cancelar cita
  Future<void> cancelarCita(String citaId) async {
    await actualizarEstadoCita(citaId, 'cancelada');
  }

  // Métodos auxiliares
  String _obtenerDiaSemana(int weekday) {
    const dias = [
      'lunes',
      'martes',
      'miercoles',
      'jueves',
      'viernes',
      'sabado',
      'domingo'
    ];
    return dias[weekday - 1];
  }

  DateTime _parsearHora(String hora) {
    final partes = hora.split(':');
    return DateTime(0, 1, 1, int.parse(partes[0]), int.parse(partes[1]));
  }
}

// notification_service.dart
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  Future<void> inicializar() async {
    // Solicitar permisos
    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // Configurar notificaciones locales
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(settings);

    // Obtener token
    final token = await _messaging.getToken();
    print('FCM Token: $token');

    // Manejar mensajes en primer plano
    FirebaseMessaging.onMessage.listen(_manejarMensajeEnPrimerPlano);
  }

  Future<String?> obtenerToken() async {
    return await _messaging.getToken();
  }

  void _manejarMensajeEnPrimerPlano(RemoteMessage message) {
    final notification = message.notification;
    if (notification != null) {
      _mostrarNotificacionLocal(
        notification.title ?? '',
        notification.body ?? '',
      );
    }
  }

  Future<void> _mostrarNotificacionLocal(String titulo, String cuerpo) async {
    const androidDetails = AndroidNotificationDetails(
      'mediturno_channel',
      'MediTurno Notifications',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _localNotifications.show(
      DateTime.now().millisecond,
      titulo,
      cuerpo,
      details,
    );
  }
}