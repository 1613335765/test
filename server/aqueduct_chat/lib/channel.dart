import 'dart:convert' as convert;

import 'package:aqueduct_chat/config/custom_config.dart';
import 'package:aqueduct/managed_auth.dart';
import 'package:aqueduct_chat/constants.dart';
import 'package:aqueduct_chat/controller/comment_controller.dart';
import 'package:aqueduct_chat/controller/friend_controller.dart';
import 'package:aqueduct_chat/controller/login_controller.dart';
import 'package:aqueduct_chat/controller/message_controller.dart';
import 'package:aqueduct_chat/controller/register__controller.dart';
import 'package:aqueduct_chat/model/message.dart';
import 'package:aqueduct_chat/model/user.dart';
import 'aqueduct_chat.dart';
import 'controller/chat_list_controller.dart';

/// This type initializes an application.
///
/// Override methods in this class to set up routes and initialize services like
/// database connections. See http://aqueduct.io/docs/http/channel/.
class AqueductChatChannel extends ApplicationChannel {
  ManagedContext context;
  AuthServer authServer;

  Map<int, WebSocket> connections = Map();

  /// Initialize services in this method.
  ///
  /// Implement this method to initialize services, read values from [options]
  /// and any other initialization required before constructing [entryPoint].
  ///
  /// This method is invoked prior to [entryPoint] being accessed.
  @override
  Future prepare() async {
    logger.onRecord.listen(
        (rec) => print("$rec ${rec.error ?? ""} ${rec.stackTrace ?? ""}"));

    final config = CustomConfig(options.configurationFilePath);
    final dateModel = ManagedDataModel.fromCurrentMirrorSystem();
    final persistentStore = PostgreSQLPersistentStore.fromConnectionInfo(
        config.database.username,
        config.database.password,
        config.database.host,
        config.database.port,
        config.database.databaseName);

    context = ManagedContext(dateModel, persistentStore);

    final delegate = ManagedAuthDelegate<User>(context);
    authServer = AuthServer(delegate);

    messageHub.listen((event) {
      if (event is Map && event['event'] == 'websocket_broadcast') {
        dynamic e = event['message'];
        int fromUserId = event['fromUserId'] as int;

        connections.values.forEach((socket) {
//          socket.add(event['message']);
          handleEvent(e, fromUserId: fromUserId);
        });
      }
    });
  }

  /// Construct the request channel.
  ///
  /// Return an instance of some [Controller] that will be the initial receiver
  /// of all [Request]s.
  ///
  /// This method is invoked after [prepare].
  @override
  Controller get entryPoint {
    final router = Router();

    // Prefer to use `link` instead of `linkFunction`.
    // See: https://aqueduct.io/docs/http/request_controller/
    router.route("/example").linkFunction((request) async {
      return Response.ok({"key": "value"});
    });

    router.route("/files/*").link(() => FileController("public/"));

    router.route("auth/token").link(() => AuthController(authServer));

    router
        .route("/register")
        .link(() => RegisterController(authServer, context));

    router.route("/login").link(() => LoginController(context));

    router
        .route("/comment")
        .link(() => Authorizer.bearer(authServer))
        .link(() => CommentController());

    router
        .route("/friend")
        .link(() => Authorizer.bearer(authServer))
        .link(() => FriendController(context));

    router
        .route("/chat_list")
        .link(() => Authorizer.bearer(authServer))
        .link(() => ChatListController(context));

    //????????????????????????
    router
        .route("/connect")
        .link(() => Authorizer.bearer(authServer))
        .linkFunction((request) async {
      //???????????????id
      int userId = request.authorization.ownerID;
      var socket = await WebSocketTransformer.upgrade(request.raw);

      print("userId???$userId?????????????????????????????????");
      socket.listen((event) {
        print("server listen:${event}");
        handleEvent(event, fromUserId: userId);

        messageHub.add(
          {
            "event": "websocket_broadcast",
            "message": event,
            'fromUserId': userId,
          },
        );
      }, onDone: () {
        //socket?????????????????????????????????
        connections.remove(userId);
      });
      //????????????
      connections[userId] = socket;

      print("?????????????????????${connections.length}???");
      connections.keys.forEach((userId) {
        print("userId:$userId");
      });
      return null;
    });

    //??????????????????
    router
        .route("/message/[:id]")
        .link(() => Authorizer.bearer(authServer))
        .link(() => MessageController(context));

    return router;
  }

  //????????????
  handleEvent(dynamic event, {int fromUserId}) async {
    if (event is String) {
      try {
        var map = convert.jsonDecode(event.toString());
        //????????????id
        int toUserId = map['toUserId'] as int;
        //????????????
        String msg_content = map['msg_content'] as String;
        //????????????
        int msg_type = map['msg_type'] as int;
        Message message = await saveMessage(
            fromUserId, toUserId, msg_content, msg_type, false);

        connections.keys.forEach((key) {
          if (key == toUserId || key == fromUserId) {
            bool selfUser = key == fromUserId;
            message.selfUser = selfUser;
            connections[key].add(convert.jsonEncode(message));
            print(
                "?????????????????????????????? fromUserId:$fromUserId,toUserId:$toUserId,msg_content: $msg_content");
          }
        });
      } catch (e) {
        print("e:$e");
      }
    }
  }

  /**
   * ????????????????????????
   */
  Future<Message> saveMessage(int fromUserId, int toUserId, String msg_content,
      int msg_type, bool selfUser) async {
    Message message = Message();
    message
      ..selfUser = selfUser
      ..fromUserId = fromUserId
      ..toUserId = toUserId
      ..content = msg_content
      ..type = msg_type
      ..sendTime = DateTime.now();

    Query<Message> query = Query<Message>(context)..values = message;
    if (await query.insert() != null) {
      print("???????????????????????????${message.asMap()}");
      return message;
    } else {
      return null;
    }
  }
}
