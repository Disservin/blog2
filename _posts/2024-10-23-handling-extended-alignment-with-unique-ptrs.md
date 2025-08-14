---
date: 2024-10-23
title: Handling Extended Alignment with std::unique_ptr
description: >
  Explanation of how to manage aligned memory with std::unique_ptr in C++ for types requiring stricter or extended alignment.
tags:
 - c++
 - c++-17
---

In C++, allocations made with `new` guarantee a minimum alignment of `alignof(std::max_align_t)`, typically 16 bytes.
However, this default alignment isn't sufficient for types requiring stricter or extended alignment.
For example, a `struct` declared with `alignas(64)` needs 64-byte alignment, which standard heap allocations don't provide.

> [It is implementation-defined whether any extended alignments are supported and the contexts in which they are supported](https://eel.is/c++draft/basic.align)

[SEI CERT guideline MEM57-CPP: Avoid using default operator new for over-aligned types](
https://wiki.sei.cmu.edu/confluence/display/cplusplus/MEM57-CPP.+Avoid+using+default+operator+new+for+over-aligned+types)

Although functions like `std::aligned_alloc` can allocate memory with specific alignments, they
return raw pointers. This places the burden of manual memory management on the programmer
and goes against the RAII (Resource Acquisition Is Initialization) principles embraced in modern C++.

To tackle this, we're looking to make std::unique_ptr work smoothly with aligned memory allocations.
By adding custom deleters and factory functions, we can make sure that objects are created, destroyed, and freed with the right alignment,
all while enjoying the convenience of automatic memory management.

```c++
struct alignas(64) X {
    int a;
};

AlignedPtr<X> f() {
  return make_unique_aligned<X>();
}
```

---

The `std::unique_ptr` class template allows us to specify a custom deallocate, enabling control over how memory is deallocated.  
By defining our own allocator and deallocate, we can integrate aligned memory management into `std::unique_ptr`.

First, let's assume we have our own wrapper functions for aligned memory allocation and deallocation, which might look like:

```c++
void* std_aligned_alloc(std::size_t alignment, std::size_t size);
void std_aligned_free(void* ptr);
```

These functions serve as placeholders for aligned memory allocation and deallocation, similar to `std::aligned_alloc`.

Next up we define our `AlignedPtr` type.

```c++
template<typename T>
struct AlignedDeleter {
    void operator()(T* ptr) const { memory_deleter<T>(ptr, std_aligned_free); }
};

template<typename T>
using AlignedPtr = std::unique_ptr<T, AlignedDeleter<T>>;
```

Where the `memory_deleter` function will manage the proper object destruction and memory deallocation.
This is as simple as calling the destructor for non-trivially destructible types and then freeing the memory.

```c++
if (!ptr)
    return;

// Explicitly needed to call the destructor
if constexpr (!std::is_trivially_destructible_v<T>)
    ptr->~T();

deallocate(ptr);
```

The `if constexpr` block ensures that the destructor is only called for non-trivially destructible types,
avoiding unnecessary overhead for trivially destructible types.

Similarly, we need a memory allocator function that will construct the object in-place and return the aligned memory address, for this we can use [placement new](https://en.wikipedia.org/wiki/Placement_syntax) and afterwards call the constructor with the provided arguments.

```c++
template<typename T, typename ALLOC_FUNC, typename... Args>
T* memory_allocator(ALLOC_FUNC alloc_func, Args&&... args) {
    void* mem = alloc_func(sizeof(T));
    return new (mem) T(std::forward<Args>(args)...);
}
```

We would also like an equivalent to `std::make_unique` for our `AlignedPtr` type. This can be achieved with a simple function wrapper,
which calls our custom memory allocator and constructs the object in-place, while also forwarding any arguments.

```c++
template<typename T, typename... Args> 
AlignedPtr<T> make_unique_aligned(Args&&... args) {
    const auto func = [](std::size_t size) { return std_aligned_alloc(alignof(T), size); }; 
    T*         obj  = memory_allocator<T>(func, std::forward<Args>(args)...);

    return AlignedPtr<T>(obj);
}
```

However, we are not done yet.

Currently, this approach only supports individual objects, not arrays. To extend our AlignedPtr to handle arrays, we need to track the array size for proper deallocation. To do this, we can store the array size just before the pointer returned by the allocator. This allows us to retrieve the size during deallocation, ensuring memory is correctly freed. We need the information about the array size to call the destructor for each element.

```c++
const std::size_t array_offset = std::max(sizeof(std::size_t), alignof(ElementType));

char* mem = reinterpret_cast<char*>(alloc_func(array_offset + num * sizeof(ElementType)));

// Save the array size in the memory location
new (mem) std::size_t(num);

// Construct the array elements in-place
for (std::size_t i = 0; i < num; ++i)
    new (mem + array_offset + i * sizeof(ElementType)) ElementType();

// Need to return the pointer at the start of the array so that
// the indexing in unique_ptr<T[]> works.
return reinterpret_cast<ElementType*>(mem + array_offset);
```

The deallocation function will then move the pointer back by the array offset to retrieve the array size and  
call the destructor for each element in reverse order.

```c++
if (!ptr)
    return;

using ElementType        = std::remove_extent_t<T>;
const std::size_t offset = std::max(sizeof(std::size_t), alignof(ElementType));
char*             mem    = reinterpret_cast<char*>(ptr) - array_offset;

if constexpr (!std::is_trivially_destructible_v<ElementType>)
{
    const std::size_t size = *reinterpret_cast<std::size_t*>(mem);
 
    // Explicitly call the destructor for each element in reverse order
    for (std::size_t i = size; i-- > 0;)
        ptr[i].~ElementType();
}

deallocate(mem);
```

The `make_unique_aligned` function syntax for arrays is a bit different than for objects, as we need to provide
the array size as the first argument.

```c++
template<typename T>
AlignedPtr<T> make_unique_aligned(std::size_t num) {
    using ElementType = std::remove_extent_t<T>;

    const auto func = [](std::size_t size) { 
        return std_aligned_alloc(alignof(ElementType), size); 
    };

    ElementType* memory = memory_allocator<T>(func, num);

    return AlignedPtr<T>(memory);
}
```

Now we can use `make_unique_aligned` to create objects which are aligned to their extended alignment requirements, while
not having to rely on implementation defined behavior of `new`

---

Using `std::enable_if_t` allows our solution to work with both arrays and non-arrays, making it more general and flexible.

View the full code on [godbolt](https://godbolt.org/z/z894rMsTW)

```c++
template<typename T, typename U>
using ARRAY_T = std::enable_if_t<std::is_array_v<T>, U>;

template<typename T, typename U>
using NOT_ARRAY_T = std::enable_if_t<!std::is_array_v<T>, U>;

template<typename T, typename DeallocateFunc>
NOT_ARRAY_T<T, void> memory_deleter(T* ptr, DeallocateFunc deallocate) {
    if (!ptr)
        return;

    if constexpr (!std::is_trivially_destructible_v<T>)
        ptr->~T();

    deallocate(ptr);
}

template<typename T, typename DeallocateFunc, typename U>
ARRAY_T<T, void> memory_deleter(U* ptr, DeallocateFunc deallocate) {
    if (!ptr)
        return;

    const std::size_t offset = std::max(sizeof(std::size_t), alignof(U));
    char*             mem    = reinterpret_cast<char*>(ptr) - offset;

    if constexpr (!std::is_trivially_destructible_v<U>)
    {
        const std::size_t size = *reinterpret_cast<std::size_t*>(mem);

        for (std::size_t i = size; i-- > 0;)
            ptr[i].~U();
    }

    deallocate(mem);
}

template<typename T, typename ALLOC_FUNC, typename... Args>
NOT_ARRAY_T<T, T*> memory_allocator(ALLOC_FUNC alloc_func, Args&&... args) {
    void* mem = alloc_func(sizeof(T));
    return new (mem) T(std::forward<Args>(args)...);
}

template<typename T, typename ALLOC_FUNC>
ARRAY_T<T, std::remove_extent_t<T>*> memory_allocator(ALLOC_FUNC alloc_func, std::size_t num) {
    using ElementType = std::remove_extent_t<T>;

    const std::size_t offset = std::max(sizeof(std::size_t), alignof(ElementType));
    char*             mem = reinterpret_cast<char*>(alloc_func(offset + num * sizeof(ElementType)));

    new (mem) std::size_t(num);

    for (std::size_t i = 0; i < num; ++i)
        new (mem + offset + i * sizeof(ElementType)) ElementType();

    return reinterpret_cast<ElementType*>(mem + offset);
}

// --------------

template<typename T>
struct AlignedDeleter {
    using U = std::conditional_t<std::is_array_v<T>, std::remove_extent_t<T>, T>;

    void operator()(U* ptr) const { return memory_deleter<T>(ptr, std_aligned_free); }
};

template<typename T>
using AlignedPtr = std::unique_ptr<T, AlignedDeleter<T>>;

// make_unique_aligned for single objects
template<typename T, typename... Args>
NOT_ARRAY_T<T, AlignedPtr<T>> make_unique_aligned(Args&&... args) {
    const auto func = [](std::size_t size) { return std_aligned_alloc(alignof(T), size); };
    T*         p    = memory_allocator<T>(func, std::forward<Args>(args)...);

    return AlignedPtr<T>(p);
}

// make_unique_aligned for arrays of unknown bound
template<typename T>
ARRAY_T<T, AlignedPtr<T>> make_unique_aligned(std::size_t num) {
    using ElementType = std::remove_extent_t<T>;

    const auto func = [](std::size_t size) {
        return std_aligned_alloc(alignof(ElementType), size);
    };

    ElementType* p = memory_allocator<T>(func, num);

    return AlignedPtr<T>(p);
}
```
