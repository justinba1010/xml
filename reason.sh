for file in $(find src -regex  ".*/.*\.ml"); do
    efmt $file > $file.re
done