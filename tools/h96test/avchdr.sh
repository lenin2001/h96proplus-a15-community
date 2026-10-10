#!/bin/bash
# avchdr.sh [clip] : per-AU slice summary in decode order from trace_headers
C=${1:?usage: avchdr.sh <clip.mp4>}
ffmpeg -v trace -i $C -c copy -bsf:v trace_headers -f null - 2>&1 | \
 grep -E "Slice Header|slice_type |frame_num |num_ref_idx_active_override_flag|num_ref_idx_l[01]_active_minus1|ref_pic_list_modification_flag_l[01]|adaptive_ref_pic_marking_mode_flag|memory_management_control_operation|difference_of_pic_nums_minus1|nal_ref_idc|max_num_ref_frames|pic_order_cnt_lsb |direct_spatial_mv_pred_flag|weighted_bipred_idc|weighted_pred_flag|long_term|first_mb_in_slice" | \
 sed -E 's/^\[[^]]*\] *//; s/ +[01]+ += +/=/' | \
 awk '/Slice Header/{if(line!="")print line; n++; line=sprintf("AU%03d:",n-1); next} {gsub(/ +/," "); line=line" "$0} END{print line}'
