// 只給 Linux 測試用：沒有 Combine 的平台上，補上引擎用到的兩個名字。
#if !canImport(Combine)
protocol ObservableObject: AnyObject {}

@propertyWrapper
struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif
