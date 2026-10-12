// Waffle ModPlayer – the window (see playerwindow.h)

#include "playerwindow.h"

#include <QCloseEvent>
#include <QDir>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QFile>
#include <QFileDialog>
#include <QFileInfo>
#include <QFontDatabase>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QKeyEvent>
#include <QLabel>
#include <QLinearGradient>
#include <QMimeData>
#include <QPainter>
#include <QPushButton>
#include <QVBoxLayout>
#include <algorithm>
#include <cmath>

#include "sinescroller.h"
#include "vumeterwidget.h"
#include "waffledisk.h"

namespace {
// Workbench 1.3 colours
const QColor kBlue(0x00, 0x55, 0xAA);
const QColor kOrange(0xFF, 0x88, 0x00);
const int kTitleHeight = 56;
const qint64 kMaxModuleSize = 16 * 1024 * 1024;

QFont topaz(int pixelSize)
{
    static const QString family = [] {
        int id = QFontDatabase::addApplicationFont(":/fonts/TopazPlus_a500_v1.0.ttf");
        QStringList f = id >= 0 ? QFontDatabase::applicationFontFamilies(id) : QStringList();
        return f.isEmpty() ? QString("monospace") : f.first();
    }();
    QFont font(family);
    font.setPixelSize(pixelSize);
    font.setStyleStrategy(QFont::NoAntialias);     // the pixels of the Amiga font
    return font;
}

QString timeText(double seconds)
{
    const int s = int(seconds);
    return QString("%1:%2").arg(s / 60, 2, 10, QChar('0')).arg(s % 60, 2, 10, QChar('0'));
}
}

PlayerWindow::PlayerWindow(QWidget *parent) : QWidget(parent)
{
    qRegisterMetaType<ModInfo>("ModInfo");
    setWindowTitle("Waffle ModPlayer");
    setAcceptDrops(true);
    setMinimumSize(560, 420);
    resize(640, 460);
    setFont(topaz(16));

    // Labels in white on blue, names in orange
    auto value = [this] {
        auto *l = new QLabel(this);
        l->setStyleSheet("color: white;");
        l->setTextInteractionFlags(Qt::NoTextInteraction);
        return l;
    };
    auto name = [this](const QString &text) {
        auto *l = new QLabel(text, this);
        l->setStyleSheet(QString("color: %1;").arg(kOrange.name()));
        return l;
    };
    m_song = value();
    m_type = value();
    m_channels = value();
    m_position = value();
    m_time = value();
    m_diskLabel = value();
    m_status = value();

    auto *info = new QGridLayout;
    info->setHorizontalSpacing(12);
    info->setVerticalSpacing(2);
    info->addWidget(name("SONG"), 0, 0);
    info->addWidget(m_song, 0, 1, 1, 3);
    info->addWidget(name("TYPE"), 1, 0);
    info->addWidget(m_type, 1, 1);
    info->addWidget(name("CHANNELS"), 1, 2);
    info->addWidget(m_channels, 1, 3);
    info->addWidget(name("POSITION"), 2, 0);
    info->addWidget(m_position, 2, 1);
    info->addWidget(name("TIME"), 2, 2);
    info->addWidget(m_time, 2, 3);
    info->addWidget(name("DISK"), 3, 0);
    info->addWidget(m_diskLabel, 3, 1, 1, 3);
    info->setColumnStretch(1, 1);
    info->setColumnStretch(3, 1);

    // The "screen": VU meters and scroller on black
    auto *screen = new QWidget(this);
    screen->setAutoFillBackground(true);
    QPalette pal = screen->palette();
    pal.setColor(QPalette::Window, Qt::black);
    screen->setPalette(pal);
    m_vu = new VuMeterWidget(screen);
    m_scroller = new SineScroller(screen);
    m_scroller->setFont(topaz(24));
    m_scroller->setMinimumHeight(52);
    auto *screenLayout = new QVBoxLayout(screen);
    screenLayout->setContentsMargins(10, 10, 10, 4);
    screenLayout->addWidget(m_vu, 1);
    screenLayout->addWidget(m_scroller);

    // Buttons: grey, raised, as in Workbench 2
    auto button = [this](const QString &text) {
        auto *b = new QPushButton(text, this);
        b->setFocusPolicy(Qt::NoFocus);
        b->setStyleSheet(
            "QPushButton { background: #aaaaaa; color: black; padding: 4px 12px;"
            " border-top: 2px solid white; border-left: 2px solid white;"
            " border-bottom: 2px solid black; border-right: 2px solid black; }"
            "QPushButton:pressed { background: #8888aa;"
            " border-top: 2px solid black; border-left: 2px solid black;"
            " border-bottom: 2px solid white; border-right: 2px solid white; }");
        return b;
    };
    auto *prev = button("<<");
    m_playButton = button("PLAY");
    auto *stop = button("STOP");
    auto *next = button(">>");
    auto *open = button("OPEN");
    auto *buttons = new QHBoxLayout;
    buttons->addWidget(prev);
    buttons->addWidget(m_playButton);
    buttons->addWidget(stop);
    buttons->addWidget(next);
    buttons->addStretch(1);
    buttons->addWidget(m_status);
    buttons->addStretch(1);
    buttons->addWidget(open);

    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(12, kTitleHeight + 8, 12, 12);
    layout->setSpacing(10);
    layout->addLayout(info);
    layout->addWidget(screen, 1);
    layout->addLayout(buttons);

    // The engine, in its thread
    m_engine = new ModEngine;
    m_engine->moveToThread(&m_thread);
    connect(&m_thread, &QThread::finished, m_engine, &QObject::deleteLater);
    connect(m_engine, &ModEngine::loaded, this, &PlayerWindow::onLoaded);
    connect(m_engine, &ModEngine::failed, this, &PlayerWindow::onFailed);
    m_thread.start();

    connect(m_playButton, &QPushButton::clicked, this, &PlayerWindow::playPause);
    connect(stop, &QPushButton::clicked, m_engine, &ModEngine::stop);
    connect(prev, &QPushButton::clicked, this, [this] {
        QMetaObject::invokeMethod(m_engine, "skip", Q_ARG(int, -1));
    });
    connect(next, &QPushButton::clicked, this, [this] {
        QMetaObject::invokeMethod(m_engine, "skip", Q_ARG(int, 1));
    });
    connect(open, &QPushButton::clicked, this, &PlayerWindow::chooseFile);

    m_refresh.setInterval(33);
    connect(&m_refresh, &QTimer::timeout, this, &PlayerWindow::refresh);
    m_refresh.start();

    m_song->setText("-");
    m_status->setText("DROP A MODULE HERE");
    m_scroller->setText("WAFFLE MODPLAYER ... DOUBLE-CLICK A .MOD FILE ON A WAFFLE-FUSE FLOPPY ... ");
    m_scroller->setRunning(true);
}

PlayerWindow::~PlayerWindow()
{
    stopEngine();
}

void PlayerWindow::stopEngine()
{
    if (!m_thread.isRunning()) return;
    QMetaObject::invokeMethod(m_engine, "shutdown", Qt::BlockingQueuedConnection);
    m_thread.quit();
    m_thread.wait();
}

bool PlayerWindow::openFile(const QString &path)
{
    QFile f(path);
    if (f.size() > kMaxModuleSize)
    {
        onFailed(QFileInfo(path).fileName() + ": too big for a module");
        return false;
    }
    if (!f.open(QIODevice::ReadOnly))
    {
        onFailed(QFileInfo(path).fileName() + ": " + f.errorString());
        return false;
    }
    const QByteArray data = f.readAll();
    m_fileName = QFileInfo(path).fileName();
    const WaffleDisk disk = waffleDiskOf(path);
    if (disk.found)
    {
        // "WaffleDemo (Z:)" on a drive letter, else the volume name
        QString volume = disk.name.isEmpty() ? QDir::toNativeSeparators(disk.root) : disk.name;
        if (disk.root.size() <= 3 && disk.root.contains(':'))
            volume += QString(" (%1)").arg(disk.root.left(2));
        m_disk = QString("%1  -  waffle-fuse").arg(volume);
    }
    else
    {
        m_disk = QDir::toNativeSeparators(QFileInfo(path).absolutePath());
    }
    QMetaObject::invokeMethod(m_engine, "load", Q_ARG(QByteArray, data), Q_ARG(QString, m_fileName));
    return true;
}

void PlayerWindow::onLoaded(const ModInfo &info)
{
    const QString title = info.title.isEmpty() ? m_fileName : info.title;
    setWindowTitle(QString("%1 – Waffle ModPlayer").arg(title));
    m_song->setText(info.title.isEmpty() ? m_fileName : QString("%1  (%2)").arg(info.title, m_fileName));
    m_type->setText(info.type);
    m_channels->setText(QString::number(info.channels));
    m_diskLabel->setText(m_diskLabel->fontMetrics().elidedText(m_disk, Qt::ElideMiddle, width() - 140));
    m_diskLabel->setToolTip(m_disk);
    m_vu->setChannels(info.channels);
    m_scroller->setText(scrollText(info));
    QMetaObject::invokeMethod(m_engine, "play");
}

void PlayerWindow::onFailed(const QString &message)
{
    m_status->setText("CANNOT PLAY");
    m_song->setText(message);
    m_scroller->setText("GURU MEDITATION ... " + message.toUpper() + " ... ");
}

QString PlayerWindow::scrollText(const ModInfo &info) const
{
    const QString title = info.title.isEmpty() ? m_fileName : info.title;
    return QString("*** WAFFLE MODPLAYER ***   YOU FOUND THE SECRET OF WAFFLE-FUSE: MODULES ON ITS FLOPPIES "
                   "PLAY RIGHT HERE ...   NOW PLAYING \"%1\"  (%2, %3 CHANNELS)   ...   "
                   "MUSIC BY LIBMIKMOD, VU METERS FROM WAFFLECOPYPRO   ...   "
                   "THANKS TO ROBERT SMITH FOR THE DRAWBRIDGE AND DISKFLASHBACK, "
                   "TO RETROGIOVEDI AND FEDERICO DI DATO (RETROBIT) FOR THE WAFFLE   ...   "
                   "GREETINGS TO EVERY AMIGA FAN KEEPING THE FLOPPIES SPINNING   ...   "
                   "SPACE: PAUSE   S: STOP   ARROWS: PATTERNS   ESC: QUIT   ...   ")
        .arg(title.toUpper(), info.type.toUpper())
        .arg(info.channels);
}

void PlayerWindow::refresh()
{
    const ModState s = m_engine->state();
    m_vu->setAudioLevels(s.playing ? s.levels : QVector<float>());
    if (s.positions > 0)
        m_position->setText(QString("%1 / %2").arg(std::min(s.position + 1, s.positions), 3, 10, QChar('0')).arg(s.positions, 3, 10, QChar('0')));
    m_time->setText(timeText(s.seconds));
    if (s.positions > 0)
    {
        m_playButton->setText(s.playing ? "PAUSE" : "PLAY");
        m_status->setText(s.playing ? "PLAYING" : s.paused ? "PAUSED" : s.finished ? "THE END" : "");
    }
    m_copper += 0.05;
    update(0, 0, width(), kTitleHeight);
}

void PlayerWindow::playPause()
{
    const ModState s = m_engine->state();
    QMetaObject::invokeMethod(m_engine, s.playing ? "togglePause" : "play");
}

void PlayerWindow::chooseFile()
{
    const QString file = QFileDialog::getOpenFileName(this, "Open a module", QString(),
        "Modules (*.mod *.xm *.s3m *.it *.med *.mtm *.669 *.ult *.far *.okt *.stm);;All files (*)");
    if (!file.isEmpty()) openFile(file);
}

void PlayerWindow::paintEvent(QPaintEvent *)
{
    QPainter p(this);
    p.fillRect(rect(), kBlue);

    // Copper bars behind the title, slowly moving
    const int w = width();
    p.fillRect(0, 0, w, kTitleHeight, Qt::black);
    const QColor bars[] = {QColor(255, 60, 60), QColor(255, 160, 0), QColor(255, 255, 80),
                           QColor(60, 220, 90), QColor(70, 140, 255), QColor(200, 90, 255)};
    for (int i = 0; i < 6; ++i)
    {
        const double y = kTitleHeight / 2.0 + std::sin(m_copper + i * 0.7) * (kTitleHeight / 2.0 - 6) - 5;
        QLinearGradient g(0, y, 0, y + 10);
        g.setColorAt(0.0, Qt::black);
        g.setColorAt(0.5, bars[i]);
        g.setColorAt(1.0, Qt::black);
        p.fillRect(QRectF(0, y, w, 10), g);
    }
    p.setFont(topaz(32));
    const QString title = "WAFFLE MODPLAYER";
    const QRect r(0, 0, w, kTitleHeight);
    p.setPen(Qt::black);
    p.drawText(r.translated(3, 3), Qt::AlignCenter, title);
    p.setPen(Qt::white);
    p.drawText(r, Qt::AlignCenter, title);
}

void PlayerWindow::keyPressEvent(QKeyEvent *event)
{
    switch (event->key())
    {
    case Qt::Key_Space: playPause(); break;
    case Qt::Key_S: QMetaObject::invokeMethod(m_engine, "stop"); break;
    case Qt::Key_Left: QMetaObject::invokeMethod(m_engine, "skip", Q_ARG(int, -1)); break;
    case Qt::Key_Right: QMetaObject::invokeMethod(m_engine, "skip", Q_ARG(int, 1)); break;
    case Qt::Key_O: chooseFile(); break;
    case Qt::Key_Escape:
    case Qt::Key_Q: close(); break;
    default: QWidget::keyPressEvent(event);
    }
}

void PlayerWindow::closeEvent(QCloseEvent *event)
{
    m_refresh.stop();
    stopEngine();
    event->accept();
}

void PlayerWindow::dragEnterEvent(QDragEnterEvent *event)
{
    if (event->mimeData()->hasUrls()) event->acceptProposedAction();
}

void PlayerWindow::dropEvent(QDropEvent *event)
{
    const QList<QUrl> urls = event->mimeData()->urls();
    if (!urls.isEmpty() && urls.first().isLocalFile()) openFile(urls.first().toLocalFile());
}
