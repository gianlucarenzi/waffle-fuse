// Waffle ModPlayer – the window: song information, VU meters, buttons and the
// sine scroller, in Workbench colours with a copper bar title.

#pragma once

#include <QThread>
#include <QTimer>
#include <QWidget>

#include "modengine.h"

class QLabel;
class QPushButton;
class SineScroller;
class VuMeterWidget;

class PlayerWindow : public QWidget
{
    Q_OBJECT

public:
    explicit PlayerWindow(QWidget *parent = nullptr);
    ~PlayerWindow() override;

    bool openFile(const QString &path);
    void setMuted(bool muted) { m_engine->setMuted(muted); }

protected:
    void paintEvent(QPaintEvent *event) override;
    void keyPressEvent(QKeyEvent *event) override;
    void closeEvent(QCloseEvent *event) override;
    void dragEnterEvent(QDragEnterEvent *event) override;
    void dropEvent(QDropEvent *event) override;

private slots:
    void onLoaded(const ModInfo &info);
    void onFailed(const QString &message);
    void refresh();
    void playPause();
    void chooseFile();

private:
    void stopEngine();
    QString scrollText(const ModInfo &info) const;

    QThread m_thread;
    ModEngine *m_engine = nullptr;
    QTimer m_refresh;
    double m_copper = 0;        // animation of the title bars
    QString m_fileName;
    QString m_disk;             // "WaffleDemo (waffle-fuse)" or the folder

    QLabel *m_song = nullptr;
    QLabel *m_type = nullptr;
    QLabel *m_channels = nullptr;
    QLabel *m_position = nullptr;
    QLabel *m_time = nullptr;
    QLabel *m_diskLabel = nullptr;
    QLabel *m_status = nullptr;
    VuMeterWidget *m_vu = nullptr;
    SineScroller *m_scroller = nullptr;
    QPushButton *m_playButton = nullptr;
};
