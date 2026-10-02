cd "$(dirname "$0")"
mkdir -p final
python3 scene3.py -- res=700,200 samples=10 vehicles=bastion,maelstrom gres=300 rocks=90 cam=5,13,1.7 target=0,-2,1.9 lens=18 shiftx=-0.2 shifty=-0.01 b_yaw=40 b_turret=-75 b_elev=8 m_rel=40,15.5 m_yaw=20 m_turret=30 f_rel=60,60 sky=0.12 out=./final/prev_hd.png > final/log_hdp.txt 2>&1
python3 scene3.py -- res=2600,745 samples=56 vehicles=bastion,maelstrom gres=300 rocks=90 cam=5,13,1.7 target=0,-2,1.9 lens=18 shiftx=-0.2 shifty=-0.01 b_yaw=40 b_turret=-75 b_elev=8 m_rel=40,15.5 m_yaw=20 m_turret=30 f_rel=60,60 sky=0.12 mist=./final/mist_hd.png out=./final/hd.png > final/log_hd.txt 2>&1
python3 scene3.py -- res=2600,745 samples=8 transparent=1 vehicles=bastion,maelstrom gres=300 rocks=90 cam=5,13,1.7 target=0,-2,1.9 lens=18 shiftx=-0.2 shifty=-0.01 b_yaw=40 b_turret=-75 b_elev=8 m_rel=40,15.5 m_yaw=20 m_turret=30 f_rel=60,60 sky=0.12 out=./final/mask_hd.png > final/log_hdm.txt 2>&1
echo done > final/hd_done.txt
