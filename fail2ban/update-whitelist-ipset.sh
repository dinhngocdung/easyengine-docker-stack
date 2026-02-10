#!/bin/bash

# --- CẤU HÌNH ---
URL="https://raw.githubusercontent.com/dinhngocdung/easyengine-docker-stack/main/fail2ban/official-whitelist.conf"
LOCAL_FILE="/opt/fail2ban/official-whitelist.conf"
SET_V4="fail2ban-whitelist"
SET_V6="fail2ban-whitelist-v6"

# --- 1. TẢI FILE ---
curl -s -f $URL -o $LOCAL_FILE

if [ ! -s $LOCAL_FILE ]; then
    echo "Lỗi: Không tải được file từ GitHub!"
    exit 1
fi

# --- 2. CHUẨN BỊ IPSET ---
# Tạo set nếu chưa có (quan trọng: IPv6 phải có family inet6)
ipset create $SET_V4 hash:net -!
ipset create $SET_V6 hash:net family inet6 -!

# Xóa dữ liệu cũ
ipset flush $SET_V4
ipset flush $SET_V6

echo "Đang xử lý và nạp dữ liệu..."

# --- 3. XỬ LÝ VÀ NẠP DỮ LIỆU ---
while read -r line; do
    # Bỏ qua dòng trống hoặc comment
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    # >>> KIỂM TRA IPV6 <<<
    if [[ "$line" == *":"* ]]; then
        # Logic sửa lỗi định dạng IPv6 tại đây:
        
        # Trường hợp 1: Đã chuẩn (có chứa dấu / ví dụ: 2001:db8::/32) -> Giữ nguyên
        if [[ "$line" == *"/"* ]]; then
            TARGET_IP="$line"
        
        # Trường hợp 2: Bị cụt, không có dấu / và không có :: (Lỗi bạn đang gặp)
        # Ví dụ: 2001:4860:4801:10 -> Sửa thành 2001:4860:4801:10::/64
        elif [[ "$line" != *"::"* ]]; then
            TARGET_IP="${line}::/64"
            
        # Trường hợp 3: Có :: nhưng thiếu prefix (ít gặp hơn) -> Thêm /64 cho chắc
        else
            TARGET_IP="${line}/64"
        fi

        # Nạp vào IPSet V6, nếu lỗi thì bỏ qua dòng đó (để không dừng script)
        ipset add $SET_V6 "$TARGET_IP" -! 2>/dev/null
        
    # >>> KIỂM TRA IPV4 <<<
    else
        # IPv4 thường ít lỗi, nạp thẳng
        ipset add $SET_V4 "$line" -! 2>/dev/null
    fi

done < $LOCAL_FILE

# --- 4. KẾT THÚC ---
# Tùy chọn: Reload fail2ban để cập nhật ngay lập tức
docker exec fail2ban fail2ban-client reload > /dev/null 2>&1

echo "Hoàn tất! Đã tự động sửa lỗi cú pháp IPv6 và nạp vào IPSet."
echo "Kiểm tra thử: ipset list $SET_V6 | head -n 5"
