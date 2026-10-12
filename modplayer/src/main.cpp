// Waffle ModPlayer – an easter egg of waffle-fuse: double-click a module (.mod)
// on a floppy mounted by waffle-fuse and it plays, with the VU meters of
// WaffleCopyPRO.  Qt 6 and libmikmod.
//
//   waffle-modplayer [file]            play (Linux: a file that is not on a
//                                      waffle-fuse disk goes to the application
//                                      that had .mod files before)
//   waffle-modplayer --force <file>    play it anyway
//   waffle-modplayer --is-waffle <file>
//                                      exit 0 and print the mountpoint when the
//                                      file is on a waffle-fuse disk, else 1
//                                      (first option; no display needed, as
//                                      for --version)
//   waffle-modplayer --screenshot <png> <file>
//                                      play, save the window after 5 s, quit
//   waffle-modplayer --quit-after <seconds> <file>
//   waffle-modplayer --mute ...        no audio output (tests, screenshots)
//
// One window: a module opened while it is running plays in that window.

#include <QApplication>
#include <QCommandLineParser>
#include <QDir>
#include <QFileInfo>
#include <QFileOpenEvent>
#include <QLocalServer>
#include <QLocalSocket>
#include <QTimer>
#include <cstdio>

#include "playerwindow.h"
#include "waffledisk.h"

#ifndef WAFFLE_VERSION
#define WAFFLE_VERSION "dev"
#endif

namespace {

QString serverName()
{
    return "waffle-modplayer-" + QDir::home().dirName();
}

// macOS: the Finder opens files with an event, not on the command line
class App : public QApplication
{
public:
    using QApplication::QApplication;
    PlayerWindow *window = nullptr;
    QString pending;

protected:
    bool event(QEvent *e) override
    {
        if (e->type() == QEvent::FileOpen)
        {
            const QString file = static_cast<QFileOpenEvent *>(e)->file();
            if (window) window->openFile(file);
            else pending = file;
            return true;
        }
        return QApplication::event(e);
    }
};

}

int main(int argc, char *argv[])
{
    // Without a display (install-desktop.sh checks that the player runs, tests)
    const QString first = argc > 1 ? QString::fromLocal8Bit(argv[1]) : QString();
    if (first == "--version")
    {
        std::printf("Waffle ModPlayer %s\n", WAFFLE_VERSION);
        return 0;
    }
    if (first == "--is-waffle")
    {
        QCoreApplication core(argc, argv);
        const WaffleDisk disk = argc > 2 ? waffleDiskOf(QString::fromLocal8Bit(argv[2])) : WaffleDisk();
        if (disk.found) std::printf("%s\n", qPrintable(QDir::toNativeSeparators(disk.root)));
        return disk.found ? 0 : 1;
    }

    App app(argc, argv);
    QApplication::setApplicationName("Waffle ModPlayer");
    QApplication::setApplicationVersion(WAFFLE_VERSION);
    QApplication::setWindowIcon(QIcon(":/icons/waffle-modplayer.png"));

    QCommandLineParser parser;
    parser.setApplicationDescription("Waffle ModPlayer: modules on waffle-fuse floppies, with VU meters");
    parser.addHelpOption();
    parser.addVersionOption();
    QCommandLineOption force("force", "Play the file even when it is not on a waffle-fuse disk.");
    QCommandLineOption screenshot("screenshot", "Save the window to <png> after 5 seconds and quit.", "png");
    QCommandLineOption quitAfter("quit-after", "Quit after <seconds>.", "seconds");
    QCommandLineOption mute("mute", "No audio output (the VU meters still move).");
    parser.addOptions({force, screenshot, quitAfter, mute});
    parser.addPositionalArgument("file", "Module to play (.mod, .xm, .s3m, .it...).");
    parser.process(app);

    const QStringList files = parser.positionalArguments();
    const QString file = files.isEmpty() ? QString() : QFileInfo(files.first()).absoluteFilePath();

    // The easter egg is for waffle-fuse disks: elsewhere a module goes to the
    // player the user had before (Linux, see scripts/install-desktop.sh)
    const bool test = parser.isSet(screenshot) || parser.isSet(quitAfter);
    if (!file.isEmpty() && !parser.isSet(force) && !waffleDiskOf(file).found &&
        handOverToPreviousApp(file))
        return 0;

    // Already running: the module goes to that window
    if (!test)
    {
        QLocalSocket socket;
        socket.connectToServer(serverName());
        if (socket.waitForConnected(300))
        {
            socket.write((file.isEmpty() ? QString("show") : file).toUtf8() + '\n');
            socket.waitForBytesWritten(1000);
            return 0;
        }
    }

    PlayerWindow window;
    window.setMuted(parser.isSet(mute));
    app.window = &window;

    QLocalServer server;
    if (!test)
    {
        QLocalServer::removeServer(serverName());     // left over by a crash
        server.listen(serverName());
        QObject::connect(&server, &QLocalServer::newConnection, &window, [&] {
            QLocalSocket *client = server.nextPendingConnection();
            QObject::connect(client, &QLocalSocket::disconnected, client, &QObject::deleteLater);
            QObject::connect(client, &QLocalSocket::readyRead, &window, [client, &window] {
                while (client->canReadLine())
                {
                    const QString line = QString::fromUtf8(client->readLine()).trimmed();
                    if (line != "show" && !line.isEmpty()) window.openFile(line);
                    window.showNormal();
                    window.raise();
                    window.activateWindow();
                }
            });
        });
    }

    window.show();
    if (!file.isEmpty()) window.openFile(file);
    else if (!app.pending.isEmpty()) window.openFile(app.pending);

    if (parser.isSet(screenshot))
    {
        const QString png = parser.value(screenshot);
        QTimer::singleShot(5000, &window, [&window, png] {
            const bool ok = window.grab().save(png);
            std::printf("%s %s\n", ok ? "saved" : "cannot save", qPrintable(png));
            window.close();
        });
    }
    if (parser.isSet(quitAfter))
        QTimer::singleShot(int(parser.value(quitAfter).toDouble() * 1000), &window, &QWidget::close);

    return app.exec();
}
