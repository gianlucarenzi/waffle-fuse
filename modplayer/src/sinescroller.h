// Waffle ModPlayer – the sine scroller at the bottom of the window.
// From the SineScroller of WaffleCopyPRO (waffleCopyPRO-Universal), fine mode:
// each character rides the wave; here the text moves by pixels and the
// characters take the colours of an Amiga copper bar.

#pragma once

#include <QString>
#include <QTimer>
#include <QWidget>

class SineScroller : public QWidget
{
    Q_OBJECT

public:
    explicit SineScroller(QWidget *parent = nullptr);

    void setText(const QString &text);
    void setRunning(bool running);

protected:
    void paintEvent(QPaintEvent *event) override;

private:
    void step();

    QString m_text;
    QTimer m_timer;
    double m_offset = 0;     // pixels scrolled
    double m_phase = 0;      // of the wave
};
