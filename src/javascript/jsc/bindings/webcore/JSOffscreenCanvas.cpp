/*
    This file is part of the WebKit open source project.
    This file has been generated by generate-bindings.pl. DO NOT MODIFY!

    This library is free software; you can redistribute it and/or
    modify it under the terms of the GNU Library General Public
    License as published by the Free Software Foundation; either
    version 2 of the License, or (at your option) any later version.

    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    Library General Public License for more details.

    You should have received a copy of the GNU Library General Public License
    along with this library; see the file COPYING.LIB.  If not, write to
    the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
    Boston, MA 02110-1301, USA.
*/

#include "config.h"

#include "JSOffscreenCanvas.h"

#include "ActiveDOMObject.h"
// #include "DOMPromiseProxy.h"
#include "ExtendedDOMClientIsoSubspaces.h"
#include "ExtendedDOMIsoSubspaces.h"
// #include "JSBlob.h"
#include "JSDOMAttribute.h"
#include "JSDOMBinding.h"
#include "JSDOMConstructor.h"
#include "JSDOMConvertAny.h"
#include "JSDOMConvertInterface.h"
#include "JSDOMConvertNullable.h"
#include "JSDOMConvertNumbers.h"
// #include "JSDOMConvertPromise.h"
#include "JSDOMConvertStrings.h"
#include "JSDOMConvertUnion.h"
#include "JSDOMConvertVariadic.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMGlobalObject.h"
#include "JSDOMGlobalObjectInlines.h"
#include "JSDOMOperation.h"
// #include "JSDOMOperationReturningPromise.h"
#include "JSDOMWrapperCache.h"
// #include "JSImageBitmap.h"
#include "JSOffscreenCanvasRenderingContext2D.h"
// #include "JSWebGL2RenderingContext.h"
// #include "JSWebGLRenderingContext.h"
#include "ScriptExecutionContext.h"
#include "WebCoreJSClientData.h"
#include <JavaScriptCore/HeapAnalyzer.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSDestructibleObjectHeapCellType.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <JavaScriptCore/SubspaceInlines.h>
#include <variant>
#include <wtf/GetPtr.h>
#include <wtf/PointerPreparations.h>
#include <wtf/URL.h>

namespace WebCore {
using namespace JSC;

String convertEnumerationToString(OffscreenCanvas::RenderingContextType enumerationValue)
{
    static const NeverDestroyed<String> values[] = {
        MAKE_STATIC_STRING_IMPL("2d"),
        // MAKE_STATIC_STRING_IMPL("webgl"),
        // MAKE_STATIC_STRING_IMPL("webgl2"),
    };
    static_assert(static_cast<size_t>(OffscreenCanvas::RenderingContextType::_2d) == 0, "OffscreenCanvas::RenderingContextType::_2d is not 0 as expected");
    // static_assert(static_cast<size_t>(OffscreenCanvas::RenderingContextType::Webgl) == 1, "OffscreenCanvas::RenderingContextType::Webgl is not 1 as expected");
    // static_assert(static_cast<size_t>(OffscreenCanvas::RenderingContextType::Webgl2) == 2, "OffscreenCanvas::RenderingContextType::Webgl2 is not 2 as expected");
    ASSERT(static_cast<size_t>(enumerationValue) < WTF_ARRAY_LENGTH(values));
    return values[static_cast<size_t>(enumerationValue)];
}

template<> JSString* convertEnumerationToJS(JSGlobalObject& lexicalGlobalObject, OffscreenCanvas::RenderingContextType enumerationValue)
{
    return jsStringWithCache(lexicalGlobalObject.vm(), convertEnumerationToString(enumerationValue));
}

template<> std::optional<OffscreenCanvas::RenderingContextType> parseEnumeration<OffscreenCanvas::RenderingContextType>(JSGlobalObject& lexicalGlobalObject, JSValue value)
{
    auto stringValue = value.toWTFString(&lexicalGlobalObject);
    if (stringValue == "2d")
        return OffscreenCanvas::RenderingContextType::_2d;
    if (stringValue == "webgl")
        return OffscreenCanvas::RenderingContextType::Webgl;
    if (stringValue == "webgl2")
        return OffscreenCanvas::RenderingContextType::Webgl2;
    return std::nullopt;
}

template<> const char* expectedEnumerationValues<OffscreenCanvas::RenderingContextType>()
{
    return "\"2d\", \"webgl\", \"webgl2\"";
}

template<> OffscreenCanvas::ImageEncodeOptions convertDictionary<OffscreenCanvas::ImageEncodeOptions>(JSGlobalObject& lexicalGlobalObject, JSValue value)
{
    VM& vm = JSC::getVM(&lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    bool isNullOrUndefined = value.isUndefinedOrNull();
    auto* object = isNullOrUndefined ? nullptr : value.getObject();
    if (UNLIKELY(!isNullOrUndefined && !object)) {
        throwTypeError(&lexicalGlobalObject, throwScope);
        return {};
    }
    OffscreenCanvas::ImageEncodeOptions result;
    JSValue qualityValue;
    if (isNullOrUndefined)
        qualityValue = jsUndefined();
    else {
        qualityValue = object->get(&lexicalGlobalObject, Identifier::fromString(vm, "quality"));
        RETURN_IF_EXCEPTION(throwScope, {});
    }
    if (!qualityValue.isUndefined()) {
        result.quality = convert<IDLUnrestrictedDouble>(lexicalGlobalObject, qualityValue);
        RETURN_IF_EXCEPTION(throwScope, {});
    } else
        result.quality = 1.0;
    JSValue typeValue;
    if (isNullOrUndefined)
        typeValue = jsUndefined();
    else {
        typeValue = object->get(&lexicalGlobalObject, Identifier::fromString(vm, "type"));
        RETURN_IF_EXCEPTION(throwScope, {});
    }
    if (!typeValue.isUndefined()) {
        result.type = convert<IDLDOMString>(lexicalGlobalObject, typeValue);
        RETURN_IF_EXCEPTION(throwScope, {});
    } else
        result.type = "image/png"_s;
    return result;
}

// Functions

static JSC_DECLARE_HOST_FUNCTION(jsOffscreenCanvasPrototypeFunction_getContext);
static JSC_DECLARE_HOST_FUNCTION(jsOffscreenCanvasPrototypeFunction_transferToImageBitmap);
static JSC_DECLARE_HOST_FUNCTION(jsOffscreenCanvasPrototypeFunction_convertToBlob);

// Attributes

static JSC_DECLARE_CUSTOM_GETTER(jsOffscreenCanvasConstructor);
static JSC_DECLARE_CUSTOM_GETTER(jsOffscreenCanvas_width);
static JSC_DECLARE_CUSTOM_SETTER(setJSOffscreenCanvas_width);
static JSC_DECLARE_CUSTOM_GETTER(jsOffscreenCanvas_height);
static JSC_DECLARE_CUSTOM_SETTER(setJSOffscreenCanvas_height);

class JSOffscreenCanvasPrototype final : public JSC::JSNonFinalObject {
public:
    using Base = JSC::JSNonFinalObject;
    static JSOffscreenCanvasPrototype* create(JSC::VM& vm, JSDOMGlobalObject* globalObject, JSC::Structure* structure)
    {
        JSOffscreenCanvasPrototype* ptr = new (NotNull, JSC::allocateCell<JSOffscreenCanvasPrototype>(vm)) JSOffscreenCanvasPrototype(vm, globalObject, structure);
        ptr->finishCreation(vm);
        return ptr;
    }

    DECLARE_INFO;
    template<typename CellType, JSC::SubspaceAccess>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        STATIC_ASSERT_ISO_SUBSPACE_SHARABLE(JSOffscreenCanvasPrototype, Base);
        return &vm.plainObjectSpace();
    }
    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
    {
        return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

private:
    JSOffscreenCanvasPrototype(JSC::VM& vm, JSC::JSGlobalObject*, JSC::Structure* structure)
        : JSC::JSNonFinalObject(vm, structure)
    {
    }

    void finishCreation(JSC::VM&);
};
STATIC_ASSERT_ISO_SUBSPACE_SHARABLE(JSOffscreenCanvasPrototype, JSOffscreenCanvasPrototype::Base);

using JSOffscreenCanvasDOMConstructor = JSDOMConstructor<JSOffscreenCanvas>;

template<> EncodedJSValue JSC_HOST_CALL_ATTRIBUTES JSOffscreenCanvasDOMConstructor::construct(JSGlobalObject* lexicalGlobalObject, CallFrame* callFrame)
{
    VM& vm = lexicalGlobalObject->vm();
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto* castedThis = jsCast<JSOffscreenCanvasDOMConstructor*>(callFrame->jsCallee());
    ASSERT(castedThis);
    if (UNLIKELY(callFrame->argumentCount() < 2))
        return throwVMError(lexicalGlobalObject, throwScope, createNotEnoughArgumentsError(lexicalGlobalObject));
    auto* context = castedThis->scriptExecutionContext();
    if (UNLIKELY(!context))
        return throwConstructorScriptExecutionContextUnavailableError(*lexicalGlobalObject, throwScope, "OffscreenCanvas");
    EnsureStillAliveScope argument0 = callFrame->uncheckedArgument(0);
    auto width = convert<IDLEnforceRangeAdaptor<IDLUnsignedLong>>(*lexicalGlobalObject, argument0.value());
    RETURN_IF_EXCEPTION(throwScope, encodedJSValue());
    EnsureStillAliveScope argument1 = callFrame->uncheckedArgument(1);
    auto height = convert<IDLEnforceRangeAdaptor<IDLUnsignedLong>>(*lexicalGlobalObject, argument1.value());
    RETURN_IF_EXCEPTION(throwScope, encodedJSValue());
    auto object = OffscreenCanvas::create(*context, WTFMove(width), WTFMove(height));
    if constexpr (IsExceptionOr<decltype(object)>)
        RETURN_IF_EXCEPTION(throwScope, {});
    static_assert(TypeOrExceptionOrUnderlyingType<decltype(object)>::isRef);
    auto jsValue = toJSNewlyCreated<IDLInterface<OffscreenCanvas>>(*lexicalGlobalObject, *castedThis->globalObject(), throwScope, WTFMove(object));
    if constexpr (IsExceptionOr<decltype(object)>)
        RETURN_IF_EXCEPTION(throwScope, {});
    setSubclassStructureIfNeeded<OffscreenCanvas>(lexicalGlobalObject, callFrame, asObject(jsValue));
    RETURN_IF_EXCEPTION(throwScope, {});
    return JSValue::encode(jsValue);
}
JSC_ANNOTATE_HOST_FUNCTION(JSOffscreenCanvasDOMConstructorConstruct, JSOffscreenCanvasDOMConstructor::construct);

template<> const ClassInfo JSOffscreenCanvasDOMConstructor::s_info = { "OffscreenCanvas"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSOffscreenCanvasDOMConstructor) };

template<> JSValue JSOffscreenCanvasDOMConstructor::prototypeForStructure(JSC::VM& vm, const JSDOMGlobalObject& globalObject)
{
    return JSEventTarget::getConstructor(vm, &globalObject);
}

template<> void JSOffscreenCanvasDOMConstructor::initializeProperties(VM& vm, JSDOMGlobalObject& globalObject)
{
    putDirect(vm, vm.propertyNames->length, jsNumber(2), JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);
    JSString* nameString = jsNontrivialString(vm, "OffscreenCanvas"_s);
    m_originalName.set(vm, this, nameString);
    putDirect(vm, vm.propertyNames->name, nameString, JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);
    putDirect(vm, vm.propertyNames->prototype, JSOffscreenCanvas::prototype(vm, globalObject), JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
}

/* Hash table for prototype */

static const HashTableValue JSOffscreenCanvasPrototypeTableValues[] = {
    { "constructor", static_cast<unsigned>(JSC::PropertyAttribute::DontEnum), NoIntrinsic, { (intptr_t) static_cast<PropertySlot::GetValueFunc>(jsOffscreenCanvasConstructor), (intptr_t) static_cast<PutPropertySlot::PutValueFunc>(0) } },
    { "width", static_cast<unsigned>(JSC::PropertyAttribute::CustomAccessor | JSC::PropertyAttribute::DOMAttribute), NoIntrinsic, { (intptr_t) static_cast<PropertySlot::GetValueFunc>(jsOffscreenCanvas_width), (intptr_t) static_cast<PutPropertySlot::PutValueFunc>(setJSOffscreenCanvas_width) } },
    { "height", static_cast<unsigned>(JSC::PropertyAttribute::CustomAccessor | JSC::PropertyAttribute::DOMAttribute), NoIntrinsic, { (intptr_t) static_cast<PropertySlot::GetValueFunc>(jsOffscreenCanvas_height), (intptr_t) static_cast<PutPropertySlot::PutValueFunc>(setJSOffscreenCanvas_height) } },
    { "getContext", static_cast<unsigned>(JSC::PropertyAttribute::Function), NoIntrinsic, { (intptr_t) static_cast<RawNativeFunction>(jsOffscreenCanvasPrototypeFunction_getContext), (intptr_t)(1) } },
    // { "transferToImageBitmap", static_cast<unsigned>(JSC::PropertyAttribute::Function), NoIntrinsic, { (intptr_t) static_cast<RawNativeFunction>(jsOffscreenCanvasPrototypeFunction_transferToImageBitmap), (intptr_t)(0) } },
    // { "convertToBlob", static_cast<unsigned>(JSC::PropertyAttribute::Function), NoIntrinsic, { (intptr_t) static_cast<RawNativeFunction>(jsOffscreenCanvasPrototypeFunction_convertToBlob), (intptr_t)(0) } },
};

const ClassInfo JSOffscreenCanvasPrototype::s_info = { "OffscreenCanvas"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSOffscreenCanvasPrototype) };

void JSOffscreenCanvasPrototype::finishCreation(VM& vm)
{
    Base::finishCreation(vm);
    reifyStaticProperties(vm, JSOffscreenCanvas::info(), JSOffscreenCanvasPrototypeTableValues, *this);
    JSC_TO_STRING_TAG_WITHOUT_TRANSITION();
}

const ClassInfo JSOffscreenCanvas::s_info = { "OffscreenCanvas"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSOffscreenCanvas) };

JSOffscreenCanvas::JSOffscreenCanvas(Structure* structure, JSDOMGlobalObject& globalObject, Ref<OffscreenCanvas>&& impl)
    : JSEventTarget(structure, globalObject, WTFMove(impl))
{
}

void JSOffscreenCanvas::finishCreation(VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(vm, info()));

    // static_assert(!std::is_base_of<ActiveDOMObject, OffscreenCanvas>::value, "Interface is not marked as [ActiveDOMObject] even though implementation class subclasses ActiveDOMObject.");
}

JSObject* JSOffscreenCanvas::createPrototype(VM& vm, JSDOMGlobalObject& globalObject)
{
    return JSOffscreenCanvasPrototype::create(vm, &globalObject, JSOffscreenCanvasPrototype::createStructure(vm, &globalObject, JSEventTarget::prototype(vm, globalObject)));
}

JSObject* JSOffscreenCanvas::prototype(VM& vm, JSDOMGlobalObject& globalObject)
{
    return getDOMPrototype<JSOffscreenCanvas>(vm, globalObject);
}

JSValue JSOffscreenCanvas::getConstructor(VM& vm, const JSGlobalObject* globalObject)
{
    return getDOMConstructor<JSOffscreenCanvasDOMConstructor, DOMConstructorID::OffscreenCanvas>(vm, *jsCast<const JSDOMGlobalObject*>(globalObject));
}

JSC_DEFINE_CUSTOM_GETTER(jsOffscreenCanvasConstructor, (JSGlobalObject * lexicalGlobalObject, EncodedJSValue thisValue, PropertyName))
{
    VM& vm = JSC::getVM(lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto* prototype = jsDynamicCast<JSOffscreenCanvasPrototype*>(vm, JSValue::decode(thisValue));
    if (UNLIKELY(!prototype))
        return throwVMTypeError(lexicalGlobalObject, throwScope);
    return JSValue::encode(JSOffscreenCanvas::getConstructor(JSC::getVM(lexicalGlobalObject), prototype->globalObject()));
}

static inline JSValue jsOffscreenCanvas_widthGetter(JSGlobalObject& lexicalGlobalObject, JSOffscreenCanvas& thisObject)
{
    auto& vm = JSC::getVM(&lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto& impl = thisObject.wrapped();
    RELEASE_AND_RETURN(throwScope, (toJS<IDLEnforceRangeAdaptor<IDLUnsignedLong>>(lexicalGlobalObject, throwScope, impl.width())));
}

JSC_DEFINE_CUSTOM_GETTER(jsOffscreenCanvas_width, (JSGlobalObject * lexicalGlobalObject, EncodedJSValue thisValue, PropertyName attributeName))
{
    return IDLAttribute<JSOffscreenCanvas>::get<jsOffscreenCanvas_widthGetter, CastedThisErrorBehavior::Assert>(*lexicalGlobalObject, thisValue, attributeName);
}

static inline bool setJSOffscreenCanvas_widthSetter(JSGlobalObject& lexicalGlobalObject, JSOffscreenCanvas& thisObject, JSValue value)
{
    auto& vm = JSC::getVM(&lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto& impl = thisObject.wrapped();
    auto nativeValue = convert<IDLEnforceRangeAdaptor<IDLUnsignedLong>>(lexicalGlobalObject, value);
    RETURN_IF_EXCEPTION(throwScope, false);
    invokeFunctorPropagatingExceptionIfNecessary(lexicalGlobalObject, throwScope, [&] {
        return impl.setWidth(WTFMove(nativeValue));
    });
    return true;
}

JSC_DEFINE_CUSTOM_SETTER(setJSOffscreenCanvas_width, (JSGlobalObject * lexicalGlobalObject, EncodedJSValue thisValue, EncodedJSValue encodedValue, PropertyName attributeName))
{
    return IDLAttribute<JSOffscreenCanvas>::set<setJSOffscreenCanvas_widthSetter>(*lexicalGlobalObject, thisValue, encodedValue, attributeName);
}

static inline JSValue jsOffscreenCanvas_heightGetter(JSGlobalObject& lexicalGlobalObject, JSOffscreenCanvas& thisObject)
{
    auto& vm = JSC::getVM(&lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto& impl = thisObject.wrapped();
    RELEASE_AND_RETURN(throwScope, (toJS<IDLEnforceRangeAdaptor<IDLUnsignedLong>>(lexicalGlobalObject, throwScope, impl.height())));
}

JSC_DEFINE_CUSTOM_GETTER(jsOffscreenCanvas_height, (JSGlobalObject * lexicalGlobalObject, EncodedJSValue thisValue, PropertyName attributeName))
{
    return IDLAttribute<JSOffscreenCanvas>::get<jsOffscreenCanvas_heightGetter, CastedThisErrorBehavior::Assert>(*lexicalGlobalObject, thisValue, attributeName);
}

static inline bool setJSOffscreenCanvas_heightSetter(JSGlobalObject& lexicalGlobalObject, JSOffscreenCanvas& thisObject, JSValue value)
{
    auto& vm = JSC::getVM(&lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto& impl = thisObject.wrapped();
    auto nativeValue = convert<IDLEnforceRangeAdaptor<IDLUnsignedLong>>(lexicalGlobalObject, value);
    RETURN_IF_EXCEPTION(throwScope, false);
    invokeFunctorPropagatingExceptionIfNecessary(lexicalGlobalObject, throwScope, [&] {
        return impl.setHeight(WTFMove(nativeValue));
    });
    return true;
}

JSC_DEFINE_CUSTOM_SETTER(setJSOffscreenCanvas_height, (JSGlobalObject * lexicalGlobalObject, EncodedJSValue thisValue, EncodedJSValue encodedValue, PropertyName attributeName))
{
    return IDLAttribute<JSOffscreenCanvas>::set<setJSOffscreenCanvas_heightSetter>(*lexicalGlobalObject, thisValue, encodedValue, attributeName);
}

static inline JSC::EncodedJSValue jsOffscreenCanvasPrototypeFunction_getContextBody(JSC::JSGlobalObject* lexicalGlobalObject, JSC::CallFrame* callFrame, typename IDLOperation<JSOffscreenCanvas>::ClassParameter castedThis)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    UNUSED_PARAM(throwScope);
    UNUSED_PARAM(callFrame);
    auto& impl = castedThis->wrapped();
    if (UNLIKELY(callFrame->argumentCount() < 1))
        return throwVMError(lexicalGlobalObject, throwScope, createNotEnoughArgumentsError(lexicalGlobalObject));
    EnsureStillAliveScope argument0 = callFrame->uncheckedArgument(0);
    auto contextType = convert<IDLEnumeration<OffscreenCanvas::RenderingContextType>>(*lexicalGlobalObject, argument0.value(), [](JSC::JSGlobalObject& lexicalGlobalObject, JSC::ThrowScope& scope) { throwArgumentMustBeEnumError(lexicalGlobalObject, scope, 0, "contextType", "OffscreenCanvas", "getContext", expectedEnumerationValues<OffscreenCanvas::RenderingContextType>()); });
    RETURN_IF_EXCEPTION(throwScope, encodedJSValue());
    auto context = impl.getContext(*jsCast<JSDOMGlobalObject*>(lexicalGlobalObject), WTFMove(contextType));
    RELEASE_AND_RETURN(throwScope, JSValue::encode(toJS<IDLNullable<IDLUnion<IDLInterface<OffscreenCanvasRenderingContext2D>>>>(*lexicalGlobalObject, *castedThis->globalObject(), throwScope, context.releaseReturnValue())));
}

JSC_DEFINE_HOST_FUNCTION(jsOffscreenCanvasPrototypeFunction_getContext, (JSGlobalObject * lexicalGlobalObject, CallFrame* callFrame))
{
    return IDLOperation<JSOffscreenCanvas>::call<jsOffscreenCanvasPrototypeFunction_getContextBody>(*lexicalGlobalObject, *callFrame, "getContext");
}

// static inline JSC::EncodedJSValue jsOffscreenCanvasPrototypeFunction_transferToImageBitmapBody(JSC::JSGlobalObject* lexicalGlobalObject, JSC::CallFrame* callFrame, typename IDLOperation<JSOffscreenCanvas>::ClassParameter castedThis)
// {
//     auto& vm = JSC::getVM(lexicalGlobalObject);
//     auto throwScope = DECLARE_THROW_SCOPE(vm);
//     UNUSED_PARAM(throwScope);
//     UNUSED_PARAM(callFrame);
//     auto& impl = castedThis->wrapped();
//     RELEASE_AND_RETURN(throwScope, JSValue::encode(toJS<IDLInterface<ImageBitmap>>(*lexicalGlobalObject, *castedThis->globalObject(), throwScope, impl.transferToImageBitmap())));
// }

// JSC_DEFINE_HOST_FUNCTION(jsOffscreenCanvasPrototypeFunction_transferToImageBitmap, (JSGlobalObject * lexicalGlobalObject, CallFrame* callFrame))
// {
//     return IDLOperation<JSOffscreenCanvas>::call<jsOffscreenCanvasPrototypeFunction_transferToImageBitmapBody>(*lexicalGlobalObject, *callFrame, "transferToImageBitmap");
// }

// static inline JSC::EncodedJSValue jsOffscreenCanvasPrototypeFunction_convertToBlobBody(JSC::JSGlobalObject* lexicalGlobalObject, JSC::CallFrame* callFrame, typename IDLOperationReturningPromise<JSOffscreenCanvas>::ClassParameter castedThis, Ref<DeferredPromise>&& promise)
// {
//     auto& vm = JSC::getVM(lexicalGlobalObject);
//     auto throwScope = DECLARE_THROW_SCOPE(vm);
//     UNUSED_PARAM(throwScope);
//     UNUSED_PARAM(callFrame);
//     auto& impl = castedThis->wrapped();
//     EnsureStillAliveScope argument0 = callFrame->argument(0);
//     auto options = convert<IDLDictionary<OffscreenCanvas::ImageEncodeOptions>>(*lexicalGlobalObject, argument0.value());
//     RETURN_IF_EXCEPTION(throwScope, encodedJSValue());
//     RELEASE_AND_RETURN(throwScope, JSValue::encode(toJS<IDLPromise<IDLInterface<Blob>>>(*lexicalGlobalObject, *castedThis->globalObject(), throwScope, [&]() -> decltype(auto) { return impl.convertToBlob(WTFMove(options), WTFMove(promise)); })));
// }

// JSC_DEFINE_HOST_FUNCTION(jsOffscreenCanvasPrototypeFunction_convertToBlob, (JSGlobalObject * lexicalGlobalObject, CallFrame* callFrame))
// {
//     return IDLOperationReturningPromise<JSOffscreenCanvas>::call<jsOffscreenCanvasPrototypeFunction_convertToBlobBody>(*lexicalGlobalObject, *callFrame, "convertToBlob");
// }

JSC::GCClient::IsoSubspace* JSOffscreenCanvas::subspaceForImpl(JSC::VM& vm)
{
    return WebCore::subspaceForImpl<JSOffscreenCanvas, UseCustomHeapCellType::No>(
        vm,
        [](auto& spaces) { return spaces.m_clientSubspaceForOffscreenCanvas.get(); },
        [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForOffscreenCanvas = WTFMove(space); },
        [](auto& spaces) { return spaces.m_subspaceForOffscreenCanvas.get(); },
        [](auto& spaces, auto&& space) { spaces.m_subspaceForOffscreenCanvas = WTFMove(space); });
}

void JSOffscreenCanvas::analyzeHeap(JSCell* cell, HeapAnalyzer& analyzer)
{
    auto* thisObject = jsCast<JSOffscreenCanvas*>(cell);
    analyzer.setWrappedObjectForCell(cell, &thisObject->wrapped());
    if (thisObject->scriptExecutionContext())
        analyzer.setLabelForCell(cell, "url " + thisObject->scriptExecutionContext()->url().string());
    Base::analyzeHeap(cell, analyzer);
}

bool JSOffscreenCanvasOwner::isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown> handle, void*, AbstractSlotVisitor& visitor, const char** reason)
{
    auto* jsOffscreenCanvas = jsCast<JSOffscreenCanvas*>(handle.slot()->asCell());
    if (jsOffscreenCanvas->wrapped().isFiringEventListeners()) {
        if (UNLIKELY(reason))
            *reason = "EventTarget firing event listeners";
        return true;
    }
    OffscreenCanvas* root = &jsOffscreenCanvas->wrapped();
    if (UNLIKELY(reason))
        *reason = "Reachable from OffscreenCanvas";
    return visitor.containsOpaqueRoot(root);
}

void JSOffscreenCanvasOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* jsOffscreenCanvas = static_cast<JSOffscreenCanvas*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &jsOffscreenCanvas->wrapped(), jsOffscreenCanvas);
}

// #if ENABLE(BINDING_INTEGRITY)
// #if PLATFORM(WIN)
// #pragma warning(disable : 4483)
// extern "C" {
// extern void (*const __identifier("??_7OffscreenCanvas@WebCore@@6B@")[])();
// }
// #else
// extern "C" {
// extern void* _ZTVN7WebCore15OffscreenCanvasE[];
// }
// #endif
// #endif

JSC::JSValue toJSNewlyCreated(JSC::JSGlobalObject*, JSDOMGlobalObject* globalObject, Ref<OffscreenCanvas>&& impl)
{

    //     if constexpr (std::is_polymorphic_v<OffscreenCanvas>) {
    // #if ENABLE(BINDING_INTEGRITY)
    //         const void* actualVTablePointer = getVTablePointer(impl.ptr());
    // #if PLATFORM(WIN)
    //         void* expectedVTablePointer = __identifier("??_7OffscreenCanvas@WebCore@@6B@");
    // #else
    //         void* expectedVTablePointer = &_ZTVN7WebCore15OffscreenCanvasE[2];
    // #endif

    //         // If you hit this assertion you either have a use after free bug, or
    //         // OffscreenCanvas has subclasses. If OffscreenCanvas has subclasses that get passed
    //         // to toJS() we currently require OffscreenCanvas you to opt out of binding hardening
    //         // by adding the SkipVTableValidation attribute to the interface IDL definition
    //         RELEASE_ASSERT(actualVTablePointer == expectedVTablePointer);
    // #endif

    return createWrapper<OffscreenCanvas>(globalObject, WTFMove(impl));
}

JSC::JSValue toJS(JSC::JSGlobalObject* lexicalGlobalObject, JSDOMGlobalObject* globalObject, OffscreenCanvas& impl)
{
    return wrap(lexicalGlobalObject, globalObject, impl);
}

OffscreenCanvas* JSOffscreenCanvas::toWrapped(JSC::VM& vm, JSC::JSValue value)
{
    if (auto* wrapper = jsDynamicCast<JSOffscreenCanvas*>(vm, value))
        return &wrapper->wrapped();
    return nullptr;
}
}