#include <node.h>
#include <v8.h>

extern "C" TSLanguage *tree_sitter_pplus();

void Init(v8::Local<v8::Object> exports) {
  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  exports->Set(isolate->GetCurrentContext(),
               v8::String::NewFromUtf8(isolate, "language").ToLocalChecked(),
               v8::External::New(isolate, tree_sitter_pplus())).FromJust();
}

NODE_MODULE(tree_sitter_pplus_binding, Init)
