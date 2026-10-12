// Waffle ModPlayer – playback engine: libmikmod in a thread of its own.
// Derived from the MikModPlayer of WaffleCopyPRO (waffleCopyPRO-Universal):
// here every libmikmod call happens in the engine thread, and the window reads
// a snapshot of the state (levels of the channels, position, time).

#pragma once

#include <QByteArray>
#include <QElapsedTimer>
#include <QMutex>
#include <QObject>
#include <QString>
#include <QVector>

class QTimer;
typedef struct MODULE MODULE;

struct ModInfo
{
    QString title;        // song name in the module
    QString type;         // "Protracker", "Scream Tracker 3"...
    int channels = 0;
    int positions = 0;
    QString driver;       // libmikmod output driver
};

struct ModState
{
    QVector<float> levels;   // 0..1 per channel
    int position = 0;
    int positions = 0;
    double seconds = 0;
    bool playing = false;
    bool paused = false;
    bool finished = false;
};

class ModEngine : public QObject
{
    Q_OBJECT

public:
    explicit ModEngine(QObject *parent = nullptr);
    ~ModEngine() override;

    ModState state() const;     // any thread
    void setMuted(bool muted) { m_muted = muted; }   // before the first load: no audio output

public slots:
    // Engine thread (queued calls from the window)
    void load(const QByteArray &data, const QString &name);
    void play();
    void togglePause();
    void stop();
    void skip(int positions);
    void shutdown();

signals:
    void loaded(const ModInfo &info);
    void failed(const QString &message);
    void finished();

private:
    bool initLibrary();
    void update();
    void freeModule();
    void publish(bool finishedNow = false);

    MODULE *m_module = nullptr;
    QByteArray m_data;       // the module file, to play it again from the start
    QTimer *m_timer = nullptr;
    bool m_libReady = false;
    bool m_muted = false;
    QElapsedTimer m_sinceUpdate;     // muted: the nosound driver does not keep time
    QString m_driver;
    mutable QMutex m_mutex;
    ModState m_state;
};

Q_DECLARE_METATYPE(ModInfo)
