msdf-atlas-gen \
-font /usr/share/fonts/OTF/Poppins-Medium.otf \
-type msdf \
-format png \
-imageout ./src/assets/font-poppins.png \
-json ./src/assets/font-poppins.json \
-size 48 \
-pxrange 4

msdf-atlas-gen \
-font ./src/assets/CalSans-SemiBold.otf \
-type msdf \
-format png \
-imageout ./src/assets/font-calsans.png \
-json ./src/assets/font-calsans.json \
-size 48 \
-pxrange 4
