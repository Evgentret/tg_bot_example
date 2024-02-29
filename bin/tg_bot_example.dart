import 'dart:async';
import 'dart:io' as io;
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import 'package:televerse/telegram.dart';
import 'package:televerse/televerse.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:cron/cron.dart';

//переменные, необходимые для работы с базой данных sembast
late Database db;
var store = intMapStoreFactory.store();

//cron - это механизм, позволяющий выполнять команды через заданное время
//после старта программы
final cron = Cron();

//в кавычках надо указать токен, который дает BotFather
Bot bot = Bot('2490564902756902746:562-495824-98549-28');

//порт, по которому можно будет пинговать бота
int watchdogPort=27051;

// идентификатор админа - его можно узнать с помощью https://t.me/chatIDrobot
int adminId=1234567890;

//максимальное количество сообщений от пользователей, информацию о которых
//для возможности ответа админом мы планируем хранить в локальной БД
//
//15 тысяч записей с планируемым объемом - это примерно мегабайт
//тормозить sembast начинает где-то на 30 мегабайтах, то есть на 450 тысячах записей
//Эта цифра зависит от вашего оборудования и является примерной,
//поэтому для больших ботов лучше пользоваться нормальной БД
//а пока мы планируем просто удалять информацию о более старых сообщениях если
//общее их количество превышает этот порог
int maxRecordsCount=20000;

//строка, которую будет возвращать встроенный веб-сервер
String response = 'все работает отлично';

//ссылки для кнопок - подставьте свое
String productOneLink ='https://mail.ru';
String productTwoLink ='https://yandex.ru';


String greetingMessage =
    'Наша фирма приветствует Вас!👋\n\n Ниже расположены ссылки на наши'
    ' лучшие продукты 👇👇\n\n';

String askUsPrompt = 'Перейдите в чат с живым человеком. Он знает всё 🤓\n'
    'https://t.me/your_manager_account';


//"последние" отправленный сообщения мы будем хранить в оперативной памяти
//это чревато проблемами при условии многомиллионной аудитории,
//но для маленького бота (несколько тысяч пользователей) это несущественно
//зато дает бОльшую плавность работы
//
//ID - это идентификатор чата, чтобы не удалить сообщение не у того человека
Map<ID, Message> lastMsg = {};


//Меню для первого (приветственного) сообщения
final keyboardMenu = InlineMenu()
    .text("Продукт 1 😋", (ctx) {sendLink(ctx, link: productOneLink);})
    .row()
    .text("Продукт 2 🍎", (ctx) { sendLink(ctx, link: productTwoLink);})
    .row()
    .text("Задать вопрос 🖐", askUs);

//меню для перехода в начало
final backMenu = InlineMenu().text("Назад", firstMessage);

void main() async {

  dbInit(); //инциализация db sembast
  httpStart(); //старт веб-сервера для проверки живучести
  botStart(); //запуск бота

  bot.onText(onText); //обработчик поступающих от человека текстовых сообщений

  //обработчики на остальные типы сообщений
  bot.onPhoto(errorType);
  bot.onDocument(errorType);
  bot.onVideo(errorType);
  bot.onVoice(errorType);
  bot.onVideoNote(errorType);
}


void dbInit() async {
  //запуск локального хранилища для обеспечения возможности ответа
  //администратором на сообщения.

  DatabaseFactory dbFactory = databaseFactoryIo;

  //Если файла по указанному пути не будет - он создастся автоматически
  db = await dbFactory.openDatabase('${io.Directory.current.path}/messageIds.db');

  //лучше сейчас, при старте выполнить оптимизацию файла БД.
  //это слегка затянет запуск, но убережет от проблем в будущем
  compactDb(maxRecordsCount);

  //каждые шесть часов выполняем оптимизацию БД
  //в идеале это надо привязать к конкретному времени,
  //чтобы эта работа выполнялась при минимальной загрузке бота
  cron.schedule(Schedule.parse('* 6 * * *'), () async {
    compactDb(maxRecordsCount);
  });
}


void httpStart() async {
  //запуск веб-сервера для периодической проверки жизни бота
  //т.к. бот может вылетать, может быть недоступным сервер и т.п.
  var handler = const Pipeline().addMiddleware(logRequests()).addHandler(_echoRequest);
  var server = await shelf_io.serve(handler, '0.0.0.0', watchdogPort);
  server.autoCompress = true;
  print('Serving at http://${server.address.host}:${server.port}');
}

botStart() {
  //перед запуском сразу ассоциируем с ботом обе наши менюшки
  bot.attachMenu(keyboardMenu);
  bot.attachMenu(backMenu);
  print('starting bot');

  try {
    //бот запускается этой командой, она же обрабатывает команду /start
    bot.start(firstMessage);
  } on Exception catch (e) {
    response = 'start error $e';
  }
}



void firstMessage(Context ctx) async {
  //заглавное сообщение бота, которое мы будем удалять при нажатии
  //на одну из кнопок

  //эта проверка нужна, чтобы повторно не отправлять первое сообщение
  //и должна быть заменена другой логикой, если у вас более развернутое меню
  if (lastMsg[ctx.id]==null) {

    //отправляем приветственную картинку через API
    //ID чата берем из контекста,
    //картинка в будущем должна лежать в той же папке, что и бинарник
    var lastMessage = await bot.api.sendPhoto(
      ID.create(ctx.chat!.id),
      InputFile.fromFile(io.File('${io.Directory.current.path}/main_logo.jpg')),
      caption: greetingMessage,
      replyMarkup: keyboardMenu,
    );

    //а это мы запоминаем, что в чате с этим человеком последнее отправленное
    //сообщение - наше приветственное
    lastMsg.addAll({ctx.id: lastMessage});
  }
}

removeLastMessage(Context ctx) {
  //удаляем последнее сообщение из чата
  //механизм нужен для того, чтобы при нажатии на кнопку под сообщением
  //у нас создавался эффект перехода на следующий экран

  if (ctx.chat != null) {
    ID chatId = ID.create(ctx.chat!.id);
    if (lastMsg[chatId] != null) {
      int messageId = lastMsg[chatId]!.messageId;
      try {
        bot.api.deleteMessage(chatId, messageId);
        lastMsg.remove(chatId);
      } on Exception catch (e) {
        print ('error while removeLastMessage: $e');
     }
    }
  }
}



FutureOr<void> sendLink(Context ctx, {required String link}) {
  //реакция на нажатие кнопки с отправкой ссылки:
  //удаляем приветственное сообщение и показываем ссылку с кнопкой "назад"
  removeLastMessage(ctx);
  ctx.reply(link, replyMarkup: backMenu);
}


FutureOr<void> askUs(Context ctx) {
  //реакция на нажатие кнопки "Задать вопрос"
  ctx.reply(askUsPrompt);
}

Future<void> onText(Context ctx) async {
  //реакция на полученное текстовое сообщение
  //основная задача - если это сообщение не от админа, то пересылаем его админу
  //в самом боте.
  //
  //если админ решает ответить на любое из сообщений из бота - то его ответ
  //уходит в через бота только нужному человеку
  //
  //т.к. на данный момент нельзя это реализовать автоматически, мы
  //вынуждены сохранять информацию обо всех отправленных сообщениях в локальной БД
  //
  //при этом когда мы посылаем сообщение админу, мы в первой строке пишем имя
  //отправителя и номер сообщения, по которому потом найдем ID пользователя
  //
  //В случае, если мы вместо номера сообщения будем отправлять сразу ID отправителя,
  //то необходимость в использовании локальной БД отпадает, но тогда ваш админ
  //получает возможность писать вашим клиентам в личку в обход бота


  //Если полученное текстовое сообщение - это ответ админа клиенту, то....
  if (ctx.id==ID.create(adminId) &&
      ctx.message!=null && ctx.message!.replyToMessage!=null ) {

    //...вырезаем из сообщения номер, заключенный между #
    String messageText=ctx.message!.replyToMessage!.text??'' ;
    int messageId=0;
    int startIndex = messageText.indexOf('#');
    int endIndex = messageText.indexOf('#', startIndex + 1);
    if (startIndex != -1 && endIndex != -1) {
      messageId = int.tryParse(messageText.substring(startIndex + 1, endIndex))??0;
    }

    //...затем пытаемся найти такую запись в локальной БД, и если она есть -
    //достаем оттуда ID пользователя и отправляем ему текст от админа в боте


    var user = await store.record(messageId).get(db);
    if (user!=null) {
      int userId = int.tryParse(user['userId'].toString()) ?? adminId;
      bot.api.sendMessage(
          ID.create(userId),
          ctx.message!.text ?? ''
      );
    }
  }
  //иначе, если это сообщение от обычного пользователя,
  //мы сохраняем служебную информацию в локальную БД и пересылаем текст админу
  else {
    if (ctx.from != null && ctx.message!=null){
        await store.record(ctx.message!.messageId).put(
            db,
            {'userId': ctx.from!.id, 'userName': ctx.from!.username ?? 'anon'}
        );

   }
    bot.api.sendMessage(
        ID.create(adminId),
       'От: ${ctx.message!.from!.firstName}, #${ctx.message!.messageId}#\n  ${ctx.message!.text ?? ''}'
    );
  }
}

Future<void> errorType(Context ctx) async {
  //ругаемся, если нам прислали войс или картинку или еще чего-нибудь
  ctx.reply('Извините, разрешено посылать только текст');
}

compactDb(int maxRecords) async {
  //оптимизация файла локальной БД по достижении указанного количества записей
  //при этом удаляются первые записи, оставляя в БД maxRecords записей
  //скорость работы зависит от количества записей выше maxRecords
  int recordCounts = await store.count(db);

  if (recordCounts >maxRecords) {
    store.delete(db,finder: Finder(sortOrders: [SortOrder('key')], limit: recordCounts-maxRecords));
    db.compact();
  }
}

//это ответ нашего встроенного веб-сервера для наблюдения за ботом
//поскольку периодичность запросов со стороны мы не знаем, то переменную
//response имеет смысл сделать глобальной и менять ее на нужные нам
//значения каждый раз, когда меняется состояние бота
Response _echoRequest(Request request) =>
    Response.ok('$response "${request.url}"');