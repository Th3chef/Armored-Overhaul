cd "$(dirname "$0")"
mkdir -p final
python3 scene3.py -- res=480,480 samples=12 gres=500 rocks=90 cam=4,12.5,1.7 target=0.3,-2,1.9 lens=27 shiftx=0.05 shifty=-0.12 b_yaw=40 b_turret=-75 b_elev=8 m_rel=27,-10.5 m_yaw=5 m_turret=25 f_rel=24,13.5 f_yaw=50 f_turret=-25 sky=0.12 out=./final/prev_sq.png > final/log_prev.txt 2>&1
python3 scene3.py -- res=1600,1600 samples=64 gres=500 rocks=90 cam=4,12.5,1.7 target=0.3,-2,1.9 lens=27 shiftx=0.05 shifty=-0.12 b_yaw=40 b_turret=-75 b_elev=8 m_rel=27,-10.5 m_yaw=5 m_turret=25 f_rel=24,13.5 f_yaw=50 f_turret=-25 sky=0.12 mist=./final/mist_sq.png out=./final/sq.png > final/log_sq.txt 2>&1
python3 scene3.py -- res=1600,1600 samples=8 transparent=1 gres=500 rocks=90 cam=4,12.5,1.7 target=0.3,-2,1.9 lens=27 shiftx=0.05 shifty=-0.12 b_yaw=40 b_turret=-75 b_elev=8 m_rel=27,-10.5 m_yaw=5 m_turret=25 f_rel=24,13.5 f_yaw=50 f_turret=-25 sky=0.12 out=./final/mask_sq.png > final/log_sqm.txt 2>&1
python3 scene3.py -- res=2400,1350 samples=64 gres=500 rocks=90 cam=5,13,1.7 target=0,-2,1.9 lens=30 shiftx=-0.17 shifty=-0.06 b_yaw=40 b_turret=-75 b_elev=8 m_rel=28,-10 m_yaw=0 m_turret=25 f_rel=24,-14.4 f_yaw=-30 f_turret=20 sky=0.12 mist=./final/mist_wd.png out=./final/wd.png > final/log_wd.txt 2>&1
python3 scene3.py -- res=2400,1350 samples=8 transparent=1 gres=500 rocks=90 cam=5,13,1.7 target=0,-2,1.9 lens=30 shiftx=-0.17 shifty=-0.06 b_yaw=40 b_turret=-75 b_elev=8 m_rel=28,-10 m_yaw=0 m_turret=25 f_rel=24,-14.4 f_yaw=-30 f_turret=20 sky=0.12 out=./final/mask_wd.png > final/log_wdm.txt 2>&1
echo done > final/done.txt
