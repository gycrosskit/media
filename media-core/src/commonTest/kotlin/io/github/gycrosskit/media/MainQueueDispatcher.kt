package io.github.gycrosskit.media

import kotlinx.coroutines.MainCoroutineDispatcher
import kotlinx.coroutines.Runnable
import kotlin.coroutines.CoroutineContext

/** 独立控制 Main 与消费恢复顺序；Main 内 immediate 调用保持同步。 */
internal class MainQueueDispatcher : MainCoroutineDispatcher() {
    override val immediate: MainCoroutineDispatcher get() = this
    private val tasks = ArrayDeque<Runnable>()
    private var executing = false

    override fun isDispatchNeeded(context: CoroutineContext) = !executing
    override fun dispatch(context: CoroutineContext, block: Runnable) { tasks.addLast(block) }

    fun runCurrent() {
        while (tasks.isNotEmpty()) {
            executing = true
            try { tasks.removeFirst().run() } finally { executing = false }
        }
    }
}
